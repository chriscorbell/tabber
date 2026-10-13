import CoreGraphics

/// Marks events Tabber posts so its own tap (and its own logic) never treats them as user input.
public enum SyntheticEvent {
    /// Stored in `kCGEventSourceUserData`. "TABB".
    public static let marker: Int64 = 0x5441_4242

    public static func isSynthetic(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == marker
    }

    static func mark(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: marker)
    }
}

/// Splits text into the pieces synthetic key events can carry.
public enum SyntheticText {
    /// `CGEventKeyboardSetUnicodeString` delivers at most 20 UTF-16 units per event.
    public static let maxUnitsPerEvent = 20

    public enum Segment: Equatable, Sendable {
        case text(String)
        /// Sent as a Return key press: many apps ignore a newline carried as Unicode text.
        case newline
    }

    /// Splits at line breaks (`\n`, `\r`, `\r\n`).
    public static func segments(_ text: String) -> [Segment] {
        var result: [Segment] = []
        var current = ""
        for character in text {
            if character == "\n" || character == "\r" || character == "\r\n" {
                if !current.isEmpty { result.append(.text(current)); current = "" }
                result.append(.newline)
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { result.append(.text(current)) }
        return result
    }

    /// Groups whole grapheme clusters into chunks of at most `maxUnits` UTF-16 units. A cluster longer
    /// than that on its own (long ZWJ sequences, stacked combining marks) is split between Unicode
    /// scalars, so a surrogate pair is never cut.
    public static func chunks(_ text: String, maxUnits: Int = maxUnitsPerEvent) -> [String] {
        precondition(maxUnits >= 2, "a chunk must fit a surrogate pair")
        var result: [String] = []
        var current = ""
        var currentUnits = 0
        for character in text {
            let units = character.utf16.count
            if units > maxUnits {
                if !current.isEmpty { result.append(current); current = ""; currentUnits = 0 }
                result.append(contentsOf: scalarChunks(character, maxUnits: maxUnits))
                continue
            }
            if currentUnits + units > maxUnits {
                result.append(current)
                current = ""
                currentUnits = 0
            }
            current.append(character)
            currentUnits += units
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// One piece per grapheme cluster, for character-by-character insertion.
    public static func graphemes(_ text: String, maxUnits: Int = maxUnitsPerEvent) -> [String] {
        text.flatMap { character -> [String] in
            character.utf16.count > maxUnits ? scalarChunks(character, maxUnits: maxUnits) : [String(character)]
        }
    }

    private static func scalarChunks(_ character: Character, maxUnits: Int) -> [String] {
        var result: [String] = []
        var current = String.UnicodeScalarView()
        var currentUnits = 0
        for scalar in character.unicodeScalars {
            let units = scalar.utf16.count
            if currentUnits + units > maxUnits {
                result.append(String(current))
                current = String.UnicodeScalarView()
                currentUnits = 0
            }
            current.append(scalar)
            currentUnits += units
        }
        if !current.isEmpty { result.append(String(current)) }
        return result
    }
}
