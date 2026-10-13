import Foundation
import Testing
@testable import TabberAX

@Suite struct URLExtractionTests {
    @Test func webURLs() {
        #expect(URLExtraction.url(fromString: "https://mail.google.com/mail/u/0/#inbox")?.host == "mail.google.com")
        #expect(URLExtraction.url(fromString: "  http://127.0.0.1:8765/test.html \n")?.port == 8765)
    }

    @Test func documentFileURLs() {
        let url = URLExtraction.url(fromString: "file:///private/tmp/tabber-ax/doc.txt")
        #expect(url?.isFileURL == true)
        #expect(url?.path == "/private/tmp/tabber-ax/doc.txt")
    }

    @Test func barePaths() {
        #expect(URLExtraction.url(fromString: "/Users/me/Notes/a b.txt")?.path == "/Users/me/Notes/a b.txt")
        #expect(URLExtraction.url(fromString: "~/x.txt")?.isFileURL == true)
    }

    @Test func hostsWithoutAScheme() {
        #expect(URLExtraction.url(fromString: "github.com/apple/swift")?.absoluteString == "https://github.com/apple/swift")
        #expect(URLExtraction.url(fromString: "localhost:3000/app")?.absoluteString == "https://localhost:3000/app")
        #expect(URLExtraction.url(fromString: "example.com:8080")?.port == 8080)
    }

    @Test func ignoredSchemes() {
        #expect(URLExtraction.url(fromString: "about:blank") == nil)
        #expect(URLExtraction.url(fromString: "data:text/html,<b>hi</b>") == nil)
        #expect(URLExtraction.url(fromString: "javascript:void(0)") == nil)
        #expect(URLExtraction.url(fromString: "chrome://newtab/") == nil)
    }

    @Test func notURLs() {
        #expect(URLExtraction.url(fromString: "") == nil)
        #expect(URLExtraction.url(fromString: "   ") == nil)
        #expect(URLExtraction.url(fromString: "Untitled") == nil)
        #expect(URLExtraction.url(fromString: "hello world.txt") == nil)
        #expect(URLExtraction.url(fromString: "https://") == nil)
        #expect(URLExtraction.url(fromString: ".com") == nil)
        #expect(URLExtraction.url(fromString: String(repeating: "a", count: 5000) + ".com") == nil)
    }

    @Test func mailto() {
        #expect(URLExtraction.url(fromString: "mailto:someone@example.com")?.scheme == "mailto")
    }

    @Test func unescapedSpaces() {
        let url = URLExtraction.url(fromString: "file:///Users/me/My Notes/a.txt")
        #expect(url?.isFileURL == true)
        #expect(url?.path == "/Users/me/My Notes/a.txt")
    }

    @Test func castAcceptsCFURLAndStrings() {
        let cfURL = URL(string: "https://www.example.com/path")! as CFURL
        #expect(AXCast.url(cfURL)?.host == "www.example.com")
        #expect(AXCast.url("https://example.org" as CFString)?.host == "example.org")
        #expect(AXCast.url(42 as CFNumber) == nil)
        #expect(AXCast.url(nil) == nil)
    }
}
