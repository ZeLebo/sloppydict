import AppKit
import ApplicationServices

@MainActor
struct TextTarget {
    let process: pid_t
    let element: AXUIElement

    static func capture() -> TextTarget? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let element = unsafeDowncast(value, to: AXUIElement.self)
        guard !isSecure(element) else { return nil }
        var role: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success,
              let role = role as? String,
              [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role) else { return nil }
        return TextTarget(process: app.processIdentifier, element: element)
    }

    func paste() throws {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == process,
              let current = Self.capture(), CFEqual(current.element, element) else {
            throw DictationError.message("Поле ввода изменилось. Текст в буфере, нажмите ⌘V.")
        }
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: false) else {
            throw DictationError.message("Не удалось вставить текст. Текст в буфере, нажмите ⌘V.")
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private static func isSecure(_ element: AXUIElement) -> Bool {
        var subrole: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
        return (subrole as? String) == kAXSecureTextFieldSubrole
    }
}

enum OutputMode: String, CaseIterable {
    case paste, clipboard
}

enum DeliveryOutcome: Equatable {
    case copied
    case pasteRequested
    case copiedForManualPaste(String)
}

@MainActor
enum TextDelivery {
    static func deliver(
        _ text: String, mode: OutputMode, target: TextTarget?,
        pasteboard: NSPasteboard = .general
    ) throws -> DeliveryOutcome {
        try copy(text, to: pasteboard)
        guard mode == .paste else { return .copied }
        guard let target else {
            return .copiedForManualPaste("Поле ввода недоступно. Нажмите ⌘V, чтобы вставить текст.")
        }
        do {
            try target.paste()
            return .pasteRequested
        } catch {
            return .copiedForManualPaste(error.localizedDescription)
        }
    }

    static func copy(_ text: String, to pasteboard: NSPasteboard = .general) throws {
        guard !text.isEmpty else { throw DictationError.message("Нет текста для копирования.") }
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            throw DictationError.message("Не удалось скопировать результат в буфер обмена.")
        }
    }
}
