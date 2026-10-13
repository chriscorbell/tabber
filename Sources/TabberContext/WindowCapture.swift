import CoreGraphics
import Foundation
import ScreenCaptureKit
import Vision

/// Where to look around the field, in the window's own coordinate space (points, top-left origin).
struct CaptureRegion: Equatable {
    struct Options: Equatable {
        var heightAbove: CGFloat = 900
        var heightBelow: CGFloat = 120
        /// Fields taller than this are editors whose content we already have; only the area above them is read.
        var tallFieldThreshold: CGFloat = 240
        /// Output width cap in pixels. Wider regions are captured below native scale.
        var maxPixelWidth = 2000
        /// Never downscale text below this many pixels per point; the region narrows around the field instead.
        var minimumPixelsPerPoint: CGFloat = 1.25
    }

    /// Window-local points.
    var rect: CGRect
    /// Output pixels per point.
    var scale: CGFloat

    var pixelWidth: Int { max(1, Int((rect.width * scale).rounded())) }
    var pixelHeight: Int { max(1, Int((rect.height * scale).rounded())) }

    /// The region above the field (plus a little below it), spanning the window's width, or a band centred on the
    /// field when the window is too wide to read at a legible scale. Nil when there's nothing to read.
    /// - Parameters:
    ///   - field: The field's rect in window-local points.
    ///   - windowSize: The window's size in points.
    ///   - nativeScale: The display's backing scale.
    static func make(field: CGRect, windowSize: CGSize, nativeScale: CGFloat, options: Options = Options()) -> CaptureRegion? {
        let bounds = CGRect(origin: .zero, size: windowSize)
        let f = field.intersection(bounds)
        guard !f.isNull, windowSize.width >= 1, windowSize.height >= 1 else { return nil }

        let top = max(0, f.minY - options.heightAbove)
        let bottom = f.height > options.tallFieldThreshold ? f.minY : min(bounds.maxY, f.maxY + options.heightBelow)
        guard bottom - top >= 16 else { return nil }

        let maxWidth = CGFloat(options.maxPixelWidth) / options.minimumPixelsPerPoint
        var minX: CGFloat = 0
        var width = bounds.width
        if width > maxWidth {
            width = maxWidth
            minX = min(max(0, f.midX - width / 2), bounds.maxX - width)
        }
        let rect = CGRect(x: minX, y: top, width: width, height: bottom - top).integral.intersection(bounds)
        let scale = min(max(nativeScale, 1), CGFloat(options.maxPixelWidth) / rect.width)
        return CaptureRegion(rect: rect, scale: scale)
    }
}

/// A window found on screen.
struct TargetWindow: Equatable {
    var id: CGWindowID
    /// Global Quartz points.
    var frame: CGRect
}

enum CaptureError: Error {
    case noWindow
    case notShareable
    case nothingToRead
}

enum WindowLocator {
    /// The frontmost on-screen window of `pid` containing `point` (the caret, or the field's centre), falling back to
    /// the frontmost one overlapping `field` most. Normal and floating levels only; menus, the Dock, overlays and
    /// other apps' windows (including Tabber's own ghost) never qualify.
    static func window(pid: pid_t, field: CGRect, point: CGPoint) -> TargetWindow? {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return nil }
        let menuLevel = Int(CGWindowLevelForKey(.mainMenuWindow))
        var candidates: [TargetWindow] = []
        for entry in info {
            guard (entry[kCGWindowOwnerPID as String] as? Int).map(pid_t.init) == pid,
                  let layer = entry[kCGWindowLayer as String] as? Int, layer >= 0, layer < menuLevel,
                  let number = entry[kCGWindowNumber as String] as? Int,
                  let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  frame.width >= 40, frame.height >= 40
            else { continue }
            if let alpha = entry[kCGWindowAlpha as String] as? Double, alpha <= 0.01 { continue }
            candidates.append(TargetWindow(id: CGWindowID(number), frame: frame))
        }
        // The window list is ordered front to back.
        if let hit = candidates.first(where: { $0.frame.contains(point) }) { return hit }
        let overlapping = candidates
            .map { ($0, $0.frame.intersection(field)) }
            .filter { !$0.1.isNull && $0.1.width * $0.1.height > 0 }
        return overlapping.max { $0.1.width * $0.1.height < $1.1.width * $1.1.height }?.0
    }
}

struct WindowCapture {
    var window: TargetWindow
    var region: CaptureRegion
    var image: CGImage
}

enum WindowCapturer {
    /// Captures `region` of one window with ScreenCaptureKit. Only that window is rendered, so overlapping windows,
    /// the cursor and Tabber's own overlay never appear in the image.
    static func capture(
        _ window: TargetWindow,
        field: CGRect,
        options: CaptureRegion.Options
    ) async throws -> WindowCapture {
        // ScreenCaptureKit needs a WindowServer connection; this makes sure one exists in command-line tools too.
        _ = CGMainDisplayID()

        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let scWindow = content.windows.first(where: { $0.windowID == window.id }) else {
            throw CaptureError.notShareable
        }
        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        // SCWindow.frame and the field are both in global Quartz points.
        let frame = scWindow.frame
        let localField = field.offsetBy(dx: -frame.minX, dy: -frame.minY)
        guard let region = CaptureRegion.make(
            field: localField,
            windowSize: frame.size,
            nativeScale: CGFloat(filter.pointPixelScale),
            options: options
        ) else { throw CaptureError.nothingToRead }

        let config = SCStreamConfiguration()
        // For a single-window filter the source rect is in window-local points, top-left origin.
        config.sourceRect = region.rect
        config.width = region.pixelWidth
        config.height = region.pixelHeight
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        config.captureResolution = .best
        // Don't set shouldBeOpaque: it makes Vision pick a model variant that `warmUp()` doesn't prepare, which
        // costs another compile of tens of seconds on first use.

        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return WindowCapture(window: TargetWindow(id: window.id, frame: frame), region: region, image: image)
    }
}

enum TextRecognizer {
    private static let queue = DispatchQueue(label: "app.tabber.context.ocr", qos: .utility)

    /// Recognizes text lines in `image` (which shows `region.rect` of a window) and returns them with boxes in
    /// window-local points. Runs on a background queue, one image at a time.
    ///
    /// Settings stay the same for every image: Vision compiles its models per configuration on first use (tens of
    /// seconds), so a per-image `minimumTextHeight` would risk new compiles. Tiny text is dropped afterwards instead.
    static func recognize(_ image: CGImage, region: CGRect) async throws -> [RecognizedLine] {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                request.automaticallyDetectsLanguage = true
                let handler = VNImageRequestHandler(cgImage: image, options: [:])
                do {
                    try handler.perform([request])
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                let lines: [RecognizedLine] = (request.results ?? []).compactMap { observation in
                    guard let candidate = observation.topCandidates(1).first else { return nil }
                    // Vision boxes are normalized with a bottom-left origin.
                    let bb = observation.boundingBox
                    let box = CGRect(
                        x: region.minX + bb.minX * region.width,
                        y: region.minY + (1 - bb.maxY) * region.height,
                        width: bb.width * region.width,
                        height: bb.height * region.height
                    )
                    return RecognizedLine(text: candidate.string, confidence: candidate.confidence, box: box)
                }
                continuation.resume(returning: lines)
            }
        }
    }
}
