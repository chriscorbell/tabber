import CryptoKit
import Foundation
import Security
import TabberContext
import TabberCore
import os

/// Opt-in record of what the user writes, used to make suggestions sound like them.
///
/// Two uses: a word-frequency profile that slightly favours words the user actually uses, plus words they
/// habitually write after the word before the caret (small logit biases); and a couple of recent passages
/// from the same app placed in the prompt as style examples. Entries are encrypted with AES-GCM using a
/// key kept in the Keychain, and stored only on this Mac.
///
/// The main-actor side only records the current field and reads a precomputed profile. Loading, saving,
/// encryption, the Keychain, and profile updates all run on a background queue.
@MainActor
final class WritingHistory {
    struct Entry: Codable, Sendable {
        var date: Date
        var bundleID: String
        var domain: String?
        var text: String
    }

    /// What the main thread reads: derived from the entries, published by the store.
    struct Profile: Sendable {
        var wordCounts: [String: Int] = [:]
        var followers: [String: [String: Int]] = [:]
        var recent: [Recent] = []
        var count = 0
    }

    struct Recent: Sendable {
        var bundleID: String
        var domain: String?
        var text: String
    }

    var isRecording = false {
        didSet { if isRecording, !oldValue { store.loadIfNeeded() } }
    }

    private let store: HistoryStore
    private var profile = Profile()
    private var biasCache: (strength: Double, bias: [String: Float])?
    /// The field being written in now.
    private var current: (field: FieldIdentity, text: String, accepted: Bool, typed: Int)?

    private static let minLength = 40

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tabber/History", isDirectory: true)
        store = HistoryStore(fileURL: dir.appendingPathComponent("history.bin"))
        store.onProfile = { [weak self] profile in
            DispatchQueue.main.async {
                self?.profile = profile
                self?.biasCache = nil
            }
        }
    }

    // MARK: - Recording

    func observe(_ s: FieldSnapshot) {
        guard isRecording, !s.isSecure else { return }
        if current?.field != s.field { current = (s.field, "", false, 0) }
        current?.text = s.textBeforeCaret + s.textAfterCaret
    }

    func typed(_ text: String) { current?.typed += text.count }

    func accepted(_ text: String) { current?.accepted = true }

    /// Called when focus leaves a field: keep its text if the user wrote in it with Tabber's help.
    func fieldEnded(_ s: FieldSnapshot) {
        defer { current = nil }
        guard isRecording, !s.isSecure, let c = current, c.field == s.field, c.accepted, c.typed > 10 else { return }
        let text = c.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= Self.minLength else { return }
        store.append(Entry(date: Date(), bundleID: s.app.bundleID, domain: s.domain, text: String(text.suffix(4000))))
    }

    func deleteAll() {
        profile = Profile()
        biasCache = nil
        store.deleteAll()
    }

    var count: Int { profile.count }

    func flush() { store.flush() }
    func flushIfNeeded() { store.flushIfNeeded() }

    // MARK: - Using it

    /// Up to two recent passages from the same app or website.
    func examples(for s: FieldSnapshot) -> [String] {
        guard isRecording else { return [] }
        let same = profile.recent.reversed().filter { $0.bundleID == s.app.bundleID && ($0.domain == s.domain || s.domain == nil) }
        return same.prefix(2).map { String($0.text.suffix(400)) }
    }

    /// Characteristic words plus words the user habitually writes after the word before the caret.
    func wordBias(strength: Double, app: String, before text: String) -> [String: Float] {
        var bias = wordBias(strength: strength)
        guard isRecording, strength > 0, let last = Self.lastWord(text), let next = profile.followers[last] else { return bias }
        let total = Double(next.values.reduce(0, +))
        for (word, n) in next where n >= 2 {
            // Share of times this word came next, as a capped boost.
            let share = Double(n) / total
            let boost = Float(min(1.5, strength * 2 * (0.5 + share) * Foundation.log(1 + Double(n))))
            bias[word] = max(bias[word] ?? 0, boost)
        }
        return bias
    }

    private func wordBias(strength: Double) -> [String: Float] {
        guard isRecording, strength > 0 else { return [:] }
        if let c = biasCache, c.strength == strength { return c.bias }
        // Favour words the user uses repeatedly; cap the boost so it nudges rather than overrides.
        let top = profile.wordCounts.filter { $0.value >= 3 && $0.key.count >= 3 }.sorted { $0.value > $1.value }.prefix(400)
        var bias: [String: Float] = [:]
        for (word, n) in top {
            bias[word] = Float(min(1.2, strength * 0.5 * Foundation.log(Double(n))))
        }
        biasCache = (strength, bias)
        return bias
    }

    private static func lastWord(_ text: String) -> String? {
        var words: [String] = []
        let lower = text.suffix(80).lowercased()
        lower.enumerateSubstrings(in: lower.startIndex..., options: .byWords) { w, _, _, _ in if let w { words.append(w) } }
        return words.last
    }
}

/// Owns the entries and the encrypted file. Everything runs on its private queue.
private final class HistoryStore: @unchecked Sendable {
    var onProfile: (@Sendable (WritingHistory.Profile) -> Void)?

    private let queue = DispatchQueue(label: "app.tabber.history", qos: .utility)
    private let log = Logger(subsystem: "app.tabber", category: "history")
    private let fileURL: URL
    private var entries: [WritingHistory.Entry] = []
    private var profile = WritingHistory.Profile()
    private var loaded = false
    /// Set when the file exists but couldn't be read. Nothing is written then, so it is never overwritten.
    private var readOnlyAfterFailure = false
    private var dirty = false
    private var lastSave = Date()

    private static let maxEntries = 3000

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func loadIfNeeded() {
        queue.async { self.load() }
    }

    func append(_ entry: WritingHistory.Entry) {
        queue.async {
            self.load()
            guard !self.readOnlyAfterFailure else { return }
            var entry = entry
            entry.text = SecretRedactor.redact(entry.text)
            // The same field often ends several times; replace the previous record of it.
            if let last = self.entries.last, last.bundleID == entry.bundleID, entry.text.hasPrefix(String(last.text.prefix(40))) {
                self.count(last, sign: -1)
                self.entries.removeLast()
            }
            self.entries.append(entry)
            self.count(entry, sign: 1)
            if self.entries.count > Self.maxEntries {
                let dropped = self.entries.removeFirst()
                self.count(dropped, sign: -1)
            }
            self.dirty = true
            self.publish()
        }
    }

    func deleteAll() {
        queue.async {
            self.entries = []
            self.profile = WritingHistory.Profile()
            self.dirty = false
            self.readOnlyAfterFailure = false
            self.loaded = true
            try? FileManager.default.removeItem(at: self.fileURL)
            self.publish()
        }
    }

    func flushIfNeeded() {
        queue.async { if self.dirty, Date().timeIntervalSince(self.lastSave) > 30 { self.save() } }
    }

    func flush() {
        queue.sync { if self.dirty { self.save() } }
    }

    // MARK: - Queue only

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            let box = try AES.GCM.SealedBox(combined: data)
            let plain = try AES.GCM.open(box, using: try Self.key(createIfMissing: false))
            entries = try JSONDecoder().decode([WritingHistory.Entry].self, from: plain)
            profile = WritingHistory.Profile()
            for e in entries { count(e, sign: 1) }
            publish()
        } catch {
            // Keep the file untouched: a locked keychain or a re-signed build may make this temporary.
            readOnlyAfterFailure = true
            log.error("Couldn't read writing history; leaving it untouched: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func save() {
        guard !readOnlyAfterFailure else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let data = try JSONEncoder().encode(entries)
            let sealed = try AES.GCM.seal(data, using: try Self.key(createIfMissing: true))
            guard let combined = sealed.combined else { return }
            try combined.write(to: fileURL, options: [.atomic, .completeFileProtection])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            dirty = false
            lastSave = Date()
        } catch {
            log.error("Saving writing history failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Adds or removes one entry's words from the profile.
    private func count(_ e: WritingHistory.Entry, sign: Int) {
        let lower = e.text.lowercased()
        var previous: String?
        lower.enumerateSubstrings(in: lower.startIndex..., options: .byWords) { w, _, _, _ in
            guard let w else { return }
            if !Self.stopWords.contains(w) {
                let n = (self.profile.wordCounts[w] ?? 0) + sign
                self.profile.wordCounts[w] = n > 0 ? n : nil
            }
            if let p = previous {
                var next = self.profile.followers[p] ?? [:]
                let n = (next[w] ?? 0) + sign
                next[w] = n > 0 ? n : nil
                self.profile.followers[p] = next.isEmpty ? nil : next
            }
            previous = w
        }
    }

    private func publish() {
        profile.count = entries.count
        profile.recent = entries.suffix(50).map { WritingHistory.Recent(bundleID: $0.bundleID, domain: $0.domain, text: $0.text) }
        onProfile?(profile)
    }

    /// The encryption key in the login keychain. A new key is made only when none exists at all.
    private static func key(createIfMissing: Bool) throws -> SymmetricKey {
        let service = "app.tabber.Tabber.history"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "key",
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data, data.count == 32 { return SymmetricKey(data: data) }
        guard status == errSecItemNotFound, createIfMissing else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        let key = SymmetricKey(size: .bits256)
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "key",
            kSecValueData as String: key.withUnsafeBytes { Data($0) },
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let added = SecItemAdd(add as CFDictionary, nil)
        guard added == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(added)) }
        return key
    }

    private static let stopWords: Set<String> = [
        "the", "and", "for", "that", "this", "with", "you", "your", "are", "was", "have", "has", "not", "but",
        "all", "can", "will", "just", "from", "they", "she", "his", "her", "him", "our", "out", "what", "when",
        "there", "their", "them", "then", "than", "about", "would", "could", "should", "been", "were", "which",
        "into", "also", "some", "any", "more", "very", "here", "how", "who", "why", "its", "it's", "i'm", "don't",
    ]
}
