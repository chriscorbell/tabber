import Foundation
import llama

/// Precomputed byte strings for every token, plus an index for "which tokens are consistent with these bytes".
///
/// Constrained decoding needs two queries many times per suggestion:
/// - tokens whose bytes start with a required prefix (a sorted range), and
/// - tokens whose bytes are themselves a prefix of the required bytes (a hash lookup per length).
final class TokenTable: @unchecked Sendable {
    let count: Int
    /// Bytes of each token as it appears in text.
    let bytes: [[UInt8]]
    /// Token ids that may be generated (not control, not unused).
    let generatable: [Bool]
    /// Token ids sorted by their bytes.
    private let sorted: [Int32]
    private let byBytes: [[UInt8]: Int32]
    let startsWithSpace: [Bool]
    /// Starts with a space, tab, or line break: the token begins a new word.
    let startsWithBreak: [Bool]
    let containsNewline: [Bool]
    let isEOG: [Bool]

    init(vocab: OpaquePointer) {
        let n = Int(llama_vocab_n_tokens(vocab))
        count = n
        var bytes = [[UInt8]](repeating: [], count: n)
        var generatable = [Bool](repeating: false, count: n)
        var startsWithSpace = [Bool](repeating: false, count: n)
        var startsWithBreak = [Bool](repeating: false, count: n)
        var containsNewline = [Bool](repeating: false, count: n)
        var isEOG = [Bool](repeating: false, count: n)
        var byBytes: [[UInt8]: Int32] = [:]
        byBytes.reserveCapacity(n)

        var buf = [CChar](repeating: 0, count: 256)
        for t in 0..<n {
            let id = Int32(t)
            let attr = llama_vocab_get_attr(vocab, id).rawValue
            let eog = llama_vocab_is_eog(vocab, id)
            isEOG[t] = eog
            let isControl = attr & LLAMA_TOKEN_ATTR_CONTROL.rawValue != 0
            let isUnused = attr & (LLAMA_TOKEN_ATTR_UNUSED.rawValue | LLAMA_TOKEN_ATTR_UNKNOWN.rawValue) != 0
            var len = llama_token_to_piece(vocab, id, &buf, Int32(buf.count), 0, false)
            if len < 0 {
                buf = [CChar](repeating: 0, count: Int(-len) + 1)
                len = llama_token_to_piece(vocab, id, &buf, Int32(buf.count), 0, false)
            }
            let b = len > 0 ? buf[0..<Int(len)].map { UInt8(bitPattern: $0) } : []
            bytes[t] = b
            generatable[t] = !isControl && !isUnused && !eog && !b.isEmpty
            startsWithSpace[t] = b.first == 0x20
            startsWithBreak[t] = b.first.map { $0 == 0x20 || $0 == 0x09 || $0 == 0x0A || $0 == 0x0D } ?? false
            containsNewline[t] = b.contains(0x0A) || b.contains(0x0D)
            if generatable[t], byBytes[b] == nil { byBytes[b] = id }
        }

        self.bytes = bytes
        self.generatable = generatable
        self.startsWithSpace = startsWithSpace
        self.startsWithBreak = startsWithBreak
        self.containsNewline = containsNewline
        self.isEOG = isEOG
        self.byBytes = byBytes
        self.sorted = (0..<n).filter { generatable[$0] }.map { Int32($0) }.sorted { Self.less(bytes[Int($0)], bytes[Int($1)]) }
    }

    private static func less(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        let n = min(a.count, b.count)
        var i = 0
        while i < n {
            if a[i] != b[i] { return a[i] < b[i] }
            i += 1
        }
        return a.count < b.count
    }

    private static func hasPrefix(_ a: [UInt8], _ p: ArraySlice<UInt8>) -> Bool {
        guard a.count >= p.count else { return false }
        var i = p.startIndex, j = 0
        while i < p.endIndex {
            if a[j] != p[i] { return false }
            i += 1; j += 1
        }
        return true
    }

    /// Calls `body` for every generatable token consistent with `required`: tokens that start with it,
    /// and tokens that are a non-empty prefix of it.
    func forEachConsistent(with required: ArraySlice<UInt8>, _ body: (Int32) -> Void) {
        guard !required.isEmpty else { return }
        // Tokens starting with `required`: binary search the lower bound, walk while the prefix holds.
        let key = Array(required)
        var lo = 0, hi = sorted.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if Self.less(bytes[Int(sorted[mid])], key) { lo = mid + 1 } else { hi = mid }
        }
        var i = lo
        while i < sorted.count, Self.hasPrefix(bytes[Int(sorted[i])], required) {
            body(sorted[i])
            i += 1
        }
        // Tokens that are a strict prefix of `required`.
        if required.count > 1 {
            for len in 1..<required.count {
                if let id = byBytes[Array(required.prefix(len))] { body(id) }
            }
        }
    }
}
