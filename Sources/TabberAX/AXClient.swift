import ApplicationServices
import Foundation

/// Attribute names used by the reader. Plain literals, so nothing depends on which SDK macros Swift imports.
enum AXName {
    // Element attributes
    static let role = "AXRole"
    static let subrole = "AXSubrole"
    static let roleDescription = "AXRoleDescription"
    static let value = "AXValue"
    static let title = "AXTitle"
    static let description = "AXDescription"
    static let placeholder = "AXPlaceholderValue"
    static let titleUIElement = "AXTitleUIElement"
    static let focusedUIElement = "AXFocusedUIElement"
    static let focused = "AXFocused"
    static let children = "AXChildren"
    static let parent = "AXParent"
    static let window = "AXWindow"
    static let position = "AXPosition"
    static let size = "AXSize"
    static let url = "AXURL"
    static let document = "AXDocument"
    static let selectedTextRange = "AXSelectedTextRange"
    static let numberOfCharacters = "AXNumberOfCharacters"
    static let markedRange = "AXTextInputMarkedRange"
    static let markedRangeAlt = "AXMarkedTextRange"
    static let multiLine = "AXMultiLine"
    static let editable = "AXEditable"
    static let editableAncestor = "AXEditableAncestor"
    static let selectedTextMarkerRange = "AXSelectedTextMarkerRange"
    static let markedTextMarkerRange = "AXTextInputMarkedTextMarkerRange"
    static let startTextMarker = "AXStartTextMarker"
    static let endTextMarker = "AXEndTextMarker"
    static let manualAccessibility = "AXManualAccessibility"
    static let enhancedUserInterface = "AXEnhancedUserInterface"

    // Parameterized attributes
    static let stringForRange = "AXStringForRange"
    static let boundsForRange = "AXBoundsForRange"
    static let attributedStringForRange = "AXAttributedStringForRange"
    static let textMarkerRangeForElement = "AXTextMarkerRangeForUIElement"
    static let rangeForUnorderedMarkers = "AXTextMarkerRangeForUnorderedTextMarkers"
    static let stringForMarkerRange = "AXStringForTextMarkerRange"
    static let attributedStringForMarkerRange = "AXAttributedStringForTextMarkerRange"
    static let lengthForMarkerRange = "AXLengthForTextMarkerRange"
    static let boundsForMarkerRange = "AXBoundsForTextMarkerRange"
    static let previousMarker = "AXPreviousTextMarkerForTextMarker"
    static let nextMarker = "AXNextTextMarkerForTextMarker"

    // Roles and subroles
    static let textField = "AXTextField"
    static let textArea = "AXTextArea"
    static let comboBox = "AXComboBox"
    static let searchField = "AXSearchField"
    static let secureTextField = "AXSecureTextField"
    static let webArea = "AXWebArea"
    static let group = "AXGroup"
    static let scrollArea = "AXScrollArea"
    static let windowRole = "AXWindow"
    static let applicationRole = "AXApplication"

    // Notifications
    static let focusedUIElementChanged = "AXFocusedUIElementChanged"
    static let focusedWindowChanged = "AXFocusedWindowChanged"
    static let valueChanged = "AXValueChanged"
    static let selectedTextChanged = "AXSelectedTextChanged"
    static let elementDestroyed = "AXUIElementDestroyed"
}

/// Thin wrapper over the AX C API. Every call that crosses into another process goes through here, so reads can
/// be counted and every failure turns into nil. Not thread-safe: each instance belongs to one thread.
final class AXClient {
    /// IPC calls made since the last `resetCount()`.
    private(set) var callCount = 0

    func resetCount() { callCount = 0 }

    func copy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        copyResult(element, attribute).value
    }

    func copyResult(_ element: AXUIElement, _ attribute: String) -> (value: CFTypeRef?, error: AXError) {
        callCount += 1
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        return (error == .success ? value : nil, error)
    }

    /// Several attributes in one round trip. Missing attributes come back absent from the dictionary.
    /// Returns nil when the whole call failed (some apps don't implement the batched form).
    func copyMany(_ element: AXUIElement, _ attributes: [String]) -> [String: CFTypeRef]? {
        callCount += 1
        var values: CFArray?
        let error = AXUIElementCopyMultipleAttributeValues(
            element, attributes as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &values
        )
        guard error == .success, let values, CFArrayGetCount(values) == attributes.count else { return nil }
        var result: [String: CFTypeRef] = [:]
        for (index, name) in attributes.enumerated() {
            guard let raw = CFArrayGetValueAtIndex(values, index) else { continue }
            let value = Unmanaged<CFTypeRef>.fromOpaque(raw).takeUnretainedValue()
            if AXCast.isErrorOrNull(value) { continue }
            result[name] = value
        }
        return result
    }

    /// One call per attribute, for apps that don't implement the batched call.
    func copyEach(_ element: AXUIElement, _ attributes: [String]) -> [String: CFTypeRef] {
        var result: [String: CFTypeRef] = [:]
        for name in attributes {
            let (value, error) = copyResult(element, name)
            if let value { result[name] = value }
            // A dead or hung app fails every attribute the same way; don't spend the timeout N times.
            if error == .cannotComplete || error == .invalidUIElement { break }
        }
        return result
    }

    func parameterized(_ element: AXUIElement, _ attribute: String, _ parameter: CFTypeRef) -> CFTypeRef? {
        callCount += 1
        var value: CFTypeRef?
        let error = AXUIElementCopyParameterizedAttributeValue(element, attribute as CFString, parameter, &value)
        return error == .success ? value : nil
    }

    func parameterized(_ element: AXUIElement, _ attribute: String, range: CFRange) -> CFTypeRef? {
        var range = range
        guard let parameter = AXValueCreate(.cfRange, &range) else { return nil }
        return parameterized(element, attribute, parameter)
    }

    func attributeNames(_ element: AXUIElement) -> [String] {
        callCount += 1
        var names: CFArray?
        guard AXUIElementCopyAttributeNames(element, &names) == .success, let names else { return [] }
        return (names as [AnyObject]).compactMap { $0 as? String }
    }

    func isSettable(_ element: AXUIElement, _ attribute: String) -> Bool? {
        callCount += 1
        var settable: DarwinBoolean = false
        let error = AXUIElementIsAttributeSettable(element, attribute as CFString, &settable)
        return error == .success ? settable.boolValue : nil
    }

    @discardableResult
    func set(_ element: AXUIElement, _ attribute: String, _ value: CFTypeRef) -> AXError {
        callCount += 1
        return AXUIElementSetAttributeValue(element, attribute as CFString, value)
    }
}

/// Type-checked conversions from CF values that AX hands back. AX returns whatever the app put there,
/// so every cast checks the CFTypeID first.
enum AXCast {
    static func isErrorOrNull(_ value: CFTypeRef) -> Bool {
        let type = CFGetTypeID(value)
        if type == CFNullGetTypeID() { return true }
        if type == AXValueGetTypeID() { return AXValueGetType(value as! AXValue) == .axError }
        return false
    }

    static func string(_ value: CFTypeRef?) -> String? {
        guard let value, CFGetTypeID(value) == CFStringGetTypeID() else { return nil }
        return value as! CFString as String
    }

    /// A trimmed string, or nil when empty.
    static func nonEmptyString(_ value: CFTypeRef?) -> String? {
        guard let s = string(value)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }

    static func bool(_ value: CFTypeRef?) -> Bool? {
        guard let value else { return nil }
        let type = CFGetTypeID(value)
        if type == CFBooleanGetTypeID() { return CFBooleanGetValue((value as! CFBoolean)) }
        if type == CFNumberGetTypeID() { return int(value).map { $0 != 0 } }
        return nil
    }

    static func int(_ value: CFTypeRef?) -> Int? {
        guard let value, CFGetTypeID(value) == CFNumberGetTypeID() else { return nil }
        var result: Int = 0
        guard CFNumberGetValue((value as! CFNumber), .longType, &result) else { return nil }
        return result
    }

    static func double(_ value: CFTypeRef?) -> Double? {
        guard let value, CFGetTypeID(value) == CFNumberGetTypeID() else { return nil }
        var result: Double = 0
        guard CFNumberGetValue((value as! CFNumber), .doubleType, &result) else { return nil }
        return result
    }

    static func element(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    static func elements(_ value: CFTypeRef?) -> [AXUIElement] {
        guard let value, CFGetTypeID(value) == CFArrayGetTypeID() else { return [] }
        let array = value as! CFArray
        var result: [AXUIElement] = []
        for index in 0..<CFArrayGetCount(array) {
            guard let raw = CFArrayGetValueAtIndex(array, index) else { continue }
            let item = Unmanaged<CFTypeRef>.fromOpaque(raw).takeUnretainedValue()
            if let element = element(item) { result.append(element) }
        }
        return result
    }

    private static func axValue(_ value: CFTypeRef?, _ type: AXValueType) -> AXValue? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue
        return AXValueGetType(axValue) == type ? axValue : nil
    }

    static func range(_ value: CFTypeRef?) -> CFRange? {
        guard let v = axValue(value, .cfRange) else { return nil }
        var range = CFRange()
        return AXValueGetValue(v, .cfRange, &range) ? range : nil
    }

    static func rect(_ value: CFTypeRef?) -> CGRect? {
        guard let v = axValue(value, .cgRect) else { return nil }
        var rect = CGRect.zero
        return AXValueGetValue(v, .cgRect, &rect) ? rect : nil
    }

    static func point(_ value: CFTypeRef?) -> CGPoint? {
        guard let v = axValue(value, .cgPoint) else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(v, .cgPoint, &point) ? point : nil
    }

    static func size(_ value: CFTypeRef?) -> CGSize? {
        guard let v = axValue(value, .cgSize) else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(v, .cgSize, &size) ? size : nil
    }

    static func textMarker(_ value: CFTypeRef?) -> AXTextMarker? {
        guard let value, CFGetTypeID(value) == AXTextMarkerGetTypeID() else { return nil }
        return (value as! AXTextMarker)
    }

    static func textMarkerRange(_ value: CFTypeRef?) -> AXTextMarkerRange? {
        guard let value, CFGetTypeID(value) == AXTextMarkerRangeGetTypeID() else { return nil }
        return (value as! AXTextMarkerRange)
    }

    static func attributedString(_ value: CFTypeRef?) -> NSAttributedString? {
        guard let value, CFGetTypeID(value) == CFAttributedStringGetTypeID() else { return nil }
        return (value as! CFAttributedString) as NSAttributedString
    }

    static func url(_ value: CFTypeRef?) -> URL? {
        guard let value else { return nil }
        if CFGetTypeID(value) == CFURLGetTypeID() {
            return URLExtraction.url(fromString: (value as! CFURL as URL).absoluteString)
        }
        return string(value).flatMap(URLExtraction.url(fromString:))
    }
}

/// An AXUIElement usable as a dictionary key. CFEqual/CFHash compare the remote element identity,
/// so two separately fetched references to the same element are equal.
struct ElementKey: Hashable {
    let element: AXUIElement

    static func == (lhs: ElementKey, rhs: ElementKey) -> Bool { CFEqual(lhs.element, rhs.element) }
    func hash(into hasher: inout Hasher) { hasher.combine(CFHash(element)) }
}

extension AXUIElement {
    var pid: pid_t? {
        var pid: pid_t = 0
        return AXUIElementGetPid(self, &pid) == .success && pid > 0 ? pid : nil
    }
}
