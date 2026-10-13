import AppKit
import SwiftUI

/// A Lucide icon (https://lucide.dev, ISC license): stroked outlines on a 24 x 24 grid.
/// Elements are copied verbatim from the icon's SVG, so adding an icon means pasting its elements.
struct LucideIcon: Hashable, Sendable {
    enum Element: Hashable, Sendable {
        case path(String)
        case circle(cx: CGFloat, cy: CGFloat, r: CGFloat)
        case ellipse(cx: CGFloat, cy: CGFloat, rx: CGFloat, ry: CGFloat)
        case rect(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, rx: CGFloat)
        case line(x1: CGFloat, y1: CGFloat, x2: CGFloat, y2: CGFloat)
    }

    let name: String
    let elements: [Element]
    /// Elements drawn filled instead of stroked (used by Tabber's own mark).
    var filled: [Element] = []

    /// The outline in grid coordinates (y down).
    var strokePath: CGPath { Self.build(elements) }
    var fillPath: CGPath { Self.build(filled) }

    private static func build(_ elements: [Element]) -> CGPath {
        let path = CGMutablePath()
        for element in elements {
            switch element {
            case let .path(d):
                SVGPathParser(d).append(to: path)
            case let .circle(cx, cy, r):
                path.addEllipse(in: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r))
            case let .ellipse(cx, cy, rx, ry):
                path.addEllipse(in: CGRect(x: cx - rx, y: cy - ry, width: 2 * rx, height: 2 * ry))
            case let .rect(x, y, width, height, rx):
                let rect = CGRect(x: x, y: y, width: width, height: height)
                if rx > 0 {
                    path.addRoundedRect(in: rect, cornerWidth: min(rx, width / 2), cornerHeight: min(rx, height / 2))
                } else {
                    path.addRect(rect)
                }
            case let .line(x1, y1, x2, y2):
                path.move(to: CGPoint(x: x1, y: y1))
                path.addLine(to: CGPoint(x: x2, y: y2))
            }
        }
        return path
    }
}

// MARK: - SwiftUI

/// Draws a Lucide icon at a point size, keeping Lucide's 2-unit stroke proportional by default.
struct Icon: View {
    let icon: LucideIcon
    var size: CGFloat = 16
    /// Stroke width in grid units (Lucide's default is 2).
    var weight: CGFloat = 2

    init(_ icon: LucideIcon, size: CGFloat = 16, weight: CGFloat = 2) {
        self.icon = icon
        self.size = size
        self.weight = weight
    }

    var body: some View {
        ZStack {
            GridShape(path: Path(icon.strokePath))
                .stroke(style: StrokeStyle(lineWidth: weight * size / 24, lineCap: .round, lineJoin: .round))
            if !icon.filled.isEmpty {
                GridShape(path: Path(icon.fillPath)).fill()
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Scales a path from the 24-unit grid into the frame.
private struct GridShape: Shape {
    let path: Path

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 24
        let transform = CGAffineTransform(translationX: rect.midX - 12 * scale, y: rect.midY - 12 * scale)
            .scaledBy(x: scale, y: scale)
        return path.applying(transform)
    }
}

// MARK: - AppKit

extension LucideIcon {
    /// A template image for menus and the status bar.
    func image(size: CGFloat = 16, weight: CGFloat = 2, template: Bool = true) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let scale = rect.width / 24
            context.scaleBy(x: scale, y: scale)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.setLineWidth(weight)
            context.setStrokeColor(NSColor.black.cgColor)
            context.setFillColor(NSColor.black.cgColor)
            context.addPath(strokePath)
            context.strokePath()
            if !filled.isEmpty {
                context.addPath(fillPath)
                context.fillPath()
            }
            return true
        }
        image.isTemplate = template
        image.accessibilityDescription = name
        return image
    }
}

// MARK: - SVG path data

/// Parses SVG path data (all commands, absolute and relative, including arcs) into a CGPath.
struct SVGPathParser {
    private let scalars: [Character]
    private var index = 0

    init(_ d: String) {
        scalars = Array(d)
    }

    func append(to path: CGMutablePath) {
        var parser = self
        parser.run(path)
    }

    private mutating func run(_ path: CGMutablePath) {
        var current = CGPoint.zero
        var start = CGPoint.zero
        var lastControl: CGPoint?
        var lastCommand: Character = " "
        var command: Character = " "

        while true {
            skipSeparators()
            guard index < scalars.count else { break }
            let c = scalars[index]
            if c.isLetter && c != "e" && c != "E" {
                command = c
                index += 1
            } else if command == " " {
                break
            }
            // A move followed by bare coordinates continues as lines.
            let relative = command.isLowercase
            let base = relative ? current : .zero

            switch command.uppercased().first! {
            case "M":
                guard let p = point(base) else { return }
                path.move(to: p)
                current = p
                start = p
                command = relative ? "l" : "L"
                lastControl = nil
            case "L":
                guard let p = point(base) else { return }
                path.addLine(to: p)
                current = p
                lastControl = nil
            case "H":
                guard let x = number() else { return }
                current = CGPoint(x: (relative ? current.x : 0) + x, y: current.y)
                path.addLine(to: current)
                lastControl = nil
            case "V":
                guard let y = number() else { return }
                current = CGPoint(x: current.x, y: (relative ? current.y : 0) + y)
                path.addLine(to: current)
                lastControl = nil
            case "C":
                guard let c1 = point(base), let c2 = point(base), let p = point(base) else { return }
                path.addCurve(to: p, control1: c1, control2: c2)
                lastControl = c2
                current = p
            case "S":
                guard let c2 = point(base), let p = point(base) else { return }
                let c1 = "CcSs".contains(lastCommand) ? reflect(lastControl, about: current) : current
                path.addCurve(to: p, control1: c1, control2: c2)
                lastControl = c2
                current = p
            case "Q":
                guard let c = point(base), let p = point(base) else { return }
                path.addQuadCurve(to: p, control: c)
                lastControl = c
                current = p
            case "T":
                guard let p = point(base) else { return }
                let c = "QqTt".contains(lastCommand) ? reflect(lastControl, about: current) : current
                path.addQuadCurve(to: p, control: c)
                lastControl = c
                current = p
            case "A":
                guard
                    let rx = number(), let ry = number(), let rotation = number(),
                    let large = flag(), let sweep = flag(), let p = point(base)
                else { return }
                addArc(to: path, from: current, to: p, rx: rx, ry: ry, rotation: rotation, large: large, sweep: sweep)
                current = p
                lastControl = nil
            case "Z":
                path.closeSubpath()
                current = start
                lastControl = nil
                lastCommand = command
                // Z takes no arguments; stray numbers after it end the path instead of looping.
                command = " "
                continue
            default:
                return
            }
            lastCommand = command
        }
    }

    private func reflect(_ point: CGPoint?, about center: CGPoint) -> CGPoint {
        guard let point else { return center }
        return CGPoint(x: 2 * center.x - point.x, y: 2 * center.y - point.y)
    }

    private mutating func skipSeparators() {
        while index < scalars.count, scalars[index] == " " || scalars[index] == "," || scalars[index].isNewline || scalars[index] == "\t" {
            index += 1
        }
    }

    private mutating func point(_ base: CGPoint) -> CGPoint? {
        guard let x = number(), let y = number() else { return nil }
        return CGPoint(x: base.x + x, y: base.y + y)
    }

    private mutating func flag() -> Bool? {
        skipSeparators()
        guard index < scalars.count, scalars[index] == "0" || scalars[index] == "1" else { return nil }
        defer { index += 1 }
        return scalars[index] == "1"
    }

    private mutating func number() -> CGFloat? {
        skipSeparators()
        var text = ""
        var seenDot = false
        var seenExponent = false
        while index < scalars.count {
            let c = scalars[index]
            if c.isNumber {
                text.append(c)
            } else if (c == "-" || c == "+"), text.isEmpty || text.last == "e" || text.last == "E" {
                text.append(c)
            } else if c == ".", !seenDot, !seenExponent {
                seenDot = true
                text.append(c)
            } else if (c == "e" || c == "E"), !seenExponent, !text.isEmpty {
                seenExponent = true
                text.append(c)
            } else {
                break
            }
            index += 1
        }
        return Double(text).map { CGFloat($0) }
    }

    /// SVG elliptical arc, converted to cubic curves (SVG 1.1 implementation notes, F.6.5).
    private func addArc(to path: CGMutablePath, from p0: CGPoint, to p1: CGPoint, rx: CGFloat, ry: CGFloat, rotation: CGFloat, large: Bool, sweep: Bool) {
        var rx = abs(rx), ry = abs(ry)
        guard rx > 0, ry > 0, p0 != p1 else {
            path.addLine(to: p1)
            return
        }
        let phi = rotation * .pi / 180
        let cosPhi = cos(phi), sinPhi = sin(phi)
        let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
        let x1p = cosPhi * dx + sinPhi * dy
        let y1p = -sinPhi * dx + cosPhi * dy

        let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
        if lambda > 1 {
            rx *= sqrt(lambda)
            ry *= sqrt(lambda)
        }
        let numerator = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
        let denominator = rx * rx * y1p * y1p + ry * ry * x1p * x1p
        var coefficient = sqrt(max(0, numerator / denominator))
        if large == sweep { coefficient = -coefficient }
        let cxp = coefficient * rx * y1p / ry
        let cyp = -coefficient * ry * x1p / rx
        let cx = cosPhi * cxp - sinPhi * cyp + (p0.x + p1.x) / 2
        let cy = sinPhi * cxp + cosPhi * cyp + (p0.y + p1.y) / 2

        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let a = atan2(ux * vy - uy * vx, ux * vx + uy * vy)
            return a
        }
        let theta1 = angle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
        var delta = angle((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry)
        if !sweep, delta > 0 { delta -= 2 * .pi }
        if sweep, delta < 0 { delta += 2 * .pi }

        let segments = max(1, Int(ceil(abs(delta) / (.pi / 2))))
        let step = delta / CGFloat(segments)
        let k = 4 / 3 * tan(step / 4)
        var theta = theta1
        for _ in 0..<segments {
            let cos1 = cos(theta), sin1 = sin(theta)
            let cos2 = cos(theta + step), sin2 = sin(theta + step)
            func map(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: cx + rx * x * cosPhi - ry * y * sinPhi, y: cy + rx * x * sinPhi + ry * y * cosPhi)
            }
            let c1 = map(cos1 - k * sin1, sin1 + k * cos1)
            let c2 = map(cos2 + k * sin2, sin2 - k * cos2)
            let end = map(cos2, sin2)
            path.addCurve(to: end, control1: c1, control2: c2)
            theta += step
        }
    }
}
