// Renders Tabber's app icon into App/Assets.xcassets/AppIcon.appiconset.
// Usage: swift scripts/render-app-icon.swift [output.appiconset]
//
// A dark rounded square with Tabber's mark: a Tab arrow (after Lucide's arrow-right-to-line) and a
// small sparkle, the same geometry as the menu bar icon.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let output = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "App/Assets.xcassets/AppIcon.appiconset"

let canvas: CGFloat = 1024
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let space = CGColorSpace(name: CGColorSpace.displayP3)!

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        colorSpace: space,
        components: [CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255, alpha]
    )!
}

/// The macOS icon outline: a superellipse, close to Apple's continuous-corner rounded square.
func squircle(in rect: CGRect, exponent n: CGFloat = 5.2) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2
    let steps = 720
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = pow(abs(c), 2 / n) * a * (c < 0 ? -1 : 1)
        let y = pow(abs(s), 2 / n) * b * (s < 0 ? -1 : 1)
        let point = CGPoint(x: rect.midX + x, y: rect.midY + y)
        i == 0 ? path.move(to: point) : path.addLine(to: point)
    }
    path.closeSubpath()
    return path
}

func render(pixels: Int) -> CGImage {
    let context = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    let scale = CGFloat(pixels) / canvas
    context.scaleBy(x: scale, y: scale)
    // Work top-down like the 24-unit icon grid.
    context.translateBy(x: 0, y: canvas)
    context.scaleBy(x: 1, y: -1)

    let outline = squircle(in: body)

    // Soft shadow under the tile.
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0x000000, 0.32))
    context.addPath(outline)
    context.setFillColor(color(0x18181B))
    context.fillPath()
    context.restoreGState()

    // Tile: near-black with a gentle top-to-bottom lift.
    context.saveGState()
    context.addPath(outline)
    context.clip()
    let gradient = CGGradient(colorsSpace: space, colors: [color(0x2B2C31), color(0x161618)] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: 512, y: body.minY), end: CGPoint(x: 512, y: body.maxY), options: [])
    context.restoreGState()

    // Hairline edge, brighter at the top.
    context.saveGState()
    context.addPath(outline)
    context.setLineWidth(4)
    context.replacePathWithStrokedPath()
    context.clip()
    let edge = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF, 0.16), color(0xFFFFFF, 0.03)] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(edge, start: CGPoint(x: 512, y: body.minY), end: CGPoint(x: 512, y: body.maxY), options: [])
    context.restoreGState()

    // The mark, in 24-unit grid coordinates, centered on its own bounds (x 2...23, y 1...21).
    let unit: CGFloat = 24.5
    context.saveGState()
    context.translateBy(x: 512 - 12.5 * unit, y: 512 - 11 * unit)
    context.scaleBy(x: unit, y: unit)

    let arrow = CGMutablePath()
    arrow.move(to: CGPoint(x: 3, y: 15)); arrow.addLine(to: CGPoint(x: 14, y: 15))
    arrow.move(to: CGPoint(x: 10, y: 11)); arrow.addLine(to: CGPoint(x: 14, y: 15)); arrow.addLine(to: CGPoint(x: 10, y: 19))
    arrow.move(to: CGPoint(x: 18, y: 10)); arrow.addLine(to: CGPoint(x: 18, y: 20))
    context.addPath(arrow)
    context.setLineWidth(2.3)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.setStrokeColor(color(0xF4F4F5))
    context.strokePath()

    let sparkle = CGMutablePath()
    sparkle.move(to: CGPoint(x: 19.5, y: 1))
    sparkle.addQuadCurve(to: CGPoint(x: 23, y: 4.5), control: CGPoint(x: 20.13, y: 3.87))
    sparkle.addQuadCurve(to: CGPoint(x: 19.5, y: 8), control: CGPoint(x: 20.13, y: 5.13))
    sparkle.addQuadCurve(to: CGPoint(x: 16, y: 4.5), control: CGPoint(x: 18.87, y: 5.13))
    sparkle.addQuadCurve(to: CGPoint(x: 19.5, y: 1), control: CGPoint(x: 18.87, y: 3.87))
    sparkle.closeSubpath()
    context.addPath(sparkle)
    context.setFillColor(color(0xF5C462))
    context.fillPath()
    context.restoreGState()

    return context.makeImage()!
}

func write(_ image: CGImage, to path: String) {
    let url = URL(fileURLWithPath: path) as CFURL
    let destination = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("Couldn't write \(path)") }
}

try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)

var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        write(render(pixels: pixels), to: "\(output)/\(name)")
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
    }
}

let contents: [String: Any] = ["images": images, "info": ["version": 1, "author": "xcode"]]
let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: URL(fileURLWithPath: "\(output)/Contents.json"))
print("Wrote \(images.count) icons to \(output)")
