import AppKit

@main
struct DeliveryChecks {
    @MainActor
    static func main() async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }

        let text = "Привет, world! Это тест."
        let copied = try TextDelivery.deliver(text, mode: .clipboard, target: nil, pasteboard: pasteboard)
        precondition(copied == .copied)
        precondition(pasteboard.string(forType: .string) == text)

        let manual = try TextDelivery.deliver("Другой результат?", mode: .paste, target: nil, pasteboard: pasteboard)
        guard case .copiedForManualPaste(let reason) = manual else { preconditionFailure("Missing target must leave text ready for manual paste") }
        precondition(!reason.isEmpty)
        precondition(pasteboard.string(forType: .string) == "Другой результат?")

        let oldTarget = TextTarget(process: -1, element: AXUIElementCreateApplication(getpid()))
        let changed = try TextDelivery.deliver("Фокус изменился.", mode: .paste, target: oldTarget, pasteboard: pasteboard)
        guard case .copiedForManualPaste = changed else { preconditionFailure("Changed focus must keep the result in the clipboard") }
        precondition(pasteboard.string(forType: .string) == "Фокус изменился.")

        let changeCount = pasteboard.changeCount
        do {
            _ = try TextDelivery.deliver("", mode: .clipboard, target: nil, pasteboard: pasteboard)
            preconditionFailure("Empty recognition must not replace the clipboard")
        } catch is DictationError {}
        precondition(pasteboard.changeCount == changeCount)

        try await Task.sleep(for: .milliseconds(650))
        precondition(pasteboard.string(forType: .string) == "Фокус изменился.")
        precondition(pasteboard.changeCount == changeCount)
        print("5 delivery checks passed using an isolated pasteboard; no keystrokes posted.")
    }
}
