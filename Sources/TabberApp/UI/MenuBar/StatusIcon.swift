import AppKit

/// Draws the status item image: Tabber's mark, with a thin progress bar while a model downloads and a dot
/// while an update waits.
@MainActor
enum StatusIcon {
    static let size = NSSize(width: 18, height: 18)

    static func image(progress: Double?, badge: Bool = false) -> NSImage {
        let mark = LucideIcon.tabberMark
        let image = NSImage(size: size, flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let scale = rect.width / 24
            context.saveGState()
            context.scaleBy(x: scale, y: scale)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.setLineWidth(2.1)
            context.setStrokeColor(NSColor.black.cgColor)
            context.setFillColor(NSColor.black.cgColor)
            context.addPath(mark.strokePath)
            context.strokePath()
            context.addPath(mark.fillPath)
            context.fillPath()
            context.restoreGState()

            if let progress {
                // Track and fill under the arrow, in template alpha so it follows the menu bar's colors.
                let track = CGRect(x: 2.5, y: rect.height - 2, width: rect.width - 5, height: 1.5)
                context.setFillColor(NSColor.black.withAlphaComponent(0.3).cgColor)
                context.addPath(CGPath(roundedRect: track, cornerWidth: 0.75, cornerHeight: 0.75, transform: nil))
                context.fillPath()
                var fill = track
                fill.size.width = max(1.5, track.width * min(1, max(0, progress)))
                context.setFillColor(NSColor.black.cgColor)
                context.addPath(CGPath(roundedRect: fill, cornerWidth: 0.75, cornerHeight: 0.75, transform: nil))
                context.fillPath()
            }
            if badge {
                context.setFillColor(NSColor.black.cgColor)
                context.fillEllipse(in: CGRect(x: rect.width - 6, y: 0.5, width: 5.5, height: 5.5))
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Tabber"
        return image
    }
}
