import AppKit
import SwiftUI
import Testing
@testable import TabberOverlay

@Suite struct AlternativesCardTests {
    @MainActor @Test func rendersNumberedWords() throws {
        for dark in [true, false] {
            let renderer = ImageRenderer(content: AlternativesCard(words: ["meeting", "agenda", "call"], dark: dark).padding(12))
            renderer.scale = 2
            let image = try #require(renderer.nsImage)
            #expect(image.size.width > 120 && image.size.height > 20)
            if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: "/tmp/tabber-alternatives-\(dark ? "dark" : "light").png"))
            }
        }
    }
}
