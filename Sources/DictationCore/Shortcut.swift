import Foundation

public struct Shortcut: Codable, Equatable, Sendable {
    public var keyCode: UInt16
    public var modifiers: UInt64

    public init(keyCode: UInt16, modifiers: UInt64) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    public static let hold = Shortcut(keyCode: 49, modifiers: 1 << 18)
    public static let toggle = Shortcut(keyCode: 49, modifiers: (1 << 18) | (1 << 19))

    public var isValid: Bool {
        keyCode <= 126 && modifiers != 0 && modifiers & ~Self.modifierMask == 0
            && ![54, 55, 56, 57, 58, 59, 60, 61, 62, 63].contains(keyCode)
    }

    public static let modifierMask: UInt64 = (1 << 17) | (1 << 18) | (1 << 19) | (1 << 20)

    public var carbonModifiers: UInt32 {
        var result: UInt32 = 0
        if modifiers & (1 << 17) != 0 { result |= 1 << 9 }
        if modifiers & (1 << 18) != 0 { result |= 1 << 12 }
        if modifiers & (1 << 19) != 0 { result |= 1 << 11 }
        if modifiers & (1 << 20) != 0 { result |= 1 << 8 }
        return result
    }
}

public struct ShortcutPair: Codable, Equatable, Sendable {
    public var hold: Shortcut
    public var toggle: Shortcut

    public init(hold: Shortcut = .hold, toggle: Shortcut = .toggle) {
        self.hold = hold
        self.toggle = toggle
    }

    public var isValid: Bool { hold.isValid && toggle.isValid && hold != toggle }
}

public enum DictationLanguage: String, Codable, CaseIterable, Sendable {
    case mixed, inputSource, russian, english

    public func resolved(inputLanguages: [String]) -> String? {
        switch self {
        case .mixed: return nil
        case .russian: return "ru"
        case .english: return "en"
        case .inputSource:
            guard let language = inputLanguages.first?.lowercased().split(separator: "-").first,
                  language == "ru" || language == "en" else { return nil }
            return String(language)
        }
    }
}
