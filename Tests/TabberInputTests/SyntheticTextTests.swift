import Testing
@testable import TabberInput

@Suite struct Chunking {
    @Test func asciiSplitsIntoTwentyUnitChunks() {
        let text = String(repeating: "abcdefghij", count: 6)
        let chunks = SyntheticText.chunks(text)
        #expect(chunks.count == 3)
        #expect(chunks.allSatisfy { $0.utf16.count == 20 })
        #expect(chunks.joined() == text)
    }

    @Test func neverSplitsGraphemeClusters() {
        let family = "👨‍👩‍👧‍👦"   // 11 UTF-16 units, one grapheme
        let flag = "🇩🇪"           // 4 units
        let combining = "e\u{301}\u{323}" // 3 units
        let text = "Hi " + family + " and " + flag + flag + " caf" + combining + " " + family + family + "!"
        let chunks = SyntheticText.chunks(text)
        #expect(chunks.joined() == text)
        #expect(chunks.allSatisfy { $0.utf16.count <= 20 })
        // Every chunk boundary is a grapheme boundary: re-segmenting gives the same characters.
        #expect(chunks.flatMap { Array($0) } == Array(text))
        // No chunk starts or ends inside a surrogate pair.
        for chunk in chunks {
            #expect(!UTF16.isTrailSurrogate(chunk.utf16.first!))
            #expect(!UTF16.isLeadSurrogate(chunk.utf16.last!))
        }
    }

    @Test func surrogatePairAtTheBoundaryMovesToTheNextChunk() {
        let text = String(repeating: "a", count: 19) + "😀" + "b"
        let chunks = SyntheticText.chunks(text)
        #expect(chunks == [String(repeating: "a", count: 19), "😀b"])
    }

    @Test func oversizedClusterSplitsBetweenScalars() {
        // One grapheme of 1 + 30 combining marks = 31 units.
        let zalgo = "a" + String(repeating: "\u{300}", count: 30)
        #expect(zalgo.count == 1)
        let chunks = SyntheticText.chunks("x" + zalgo + "y")
        #expect(chunks.joined() == "x" + zalgo + "y")
        #expect(chunks.allSatisfy { $0.utf16.count <= 20 })

        // Long emoji ZWJ sequences split between scalars, keeping surrogate pairs whole.
        let long = Array(repeating: "👩🏽", count: 6).joined(separator: "\u{200D}")
        #expect(long.count == 1 && long.utf16.count > 20)
        for chunk in SyntheticText.chunks(long) {
            #expect(chunk.utf16.count <= 20)
            #expect(!UTF16.isTrailSurrogate(chunk.utf16.first!))
            #expect(!UTF16.isLeadSurrogate(chunk.utf16.last!))
        }
    }

    @Test func graphemesArePerCharacter() {
        #expect(SyntheticText.graphemes("e\u{301}👍🏽a") == ["e\u{301}", "👍🏽", "a"])
        #expect(SyntheticText.graphemes("") == [])
    }

    @Test func emptyTextHasNoChunks() {
        #expect(SyntheticText.chunks("") == [])
    }
}

@Suite struct Newlines {
    @Test func lineBreaksBecomeReturnPresses() {
        #expect(SyntheticText.segments("one\ntwo") == [.text("one"), .newline, .text("two")])
        #expect(SyntheticText.segments("a\r\nb\rc") == [.text("a"), .newline, .text("b"), .newline, .text("c")])
        #expect(SyntheticText.segments("\n\nx\n") == [.newline, .newline, .text("x"), .newline])
        #expect(SyntheticText.segments(" world") == [.text(" world")])
    }
}
