import Carbon
import Foundation

@main
struct HotkeyEventChecks {
    @MainActor
    static func main() async {
        var returned = false
        var received: [String] = []
        let delivery = HotkeyEventDelivery { identifier, down in
            precondition(returned, "Work must never run inside the Carbon callback")
            received.append("\(identifier):\(down ? "down" : "up")")
        }
        let pointer = Unmanaged.passUnretained(delivery).toOpaque()
        for (identifier, kind) in [(UInt32(1), kEventHotKeyPressed), (1, kEventHotKeyReleased), (2, kEventHotKeyPressed)] {
            let event = makeEvent(identifier: identifier, kind: UInt32(kind))
            precondition(registeredHotkeyHandler(nil, event, pointer) == noErr)
            ReleaseEvent(event)
        }
        precondition(received.isEmpty, "Callback must return before dispatching any work")
        returned = true
        await drainQueue()
        precondition(received == ["1:down", "1:up", "2:down"], "Press and release order must be preserved")

        let foreign = makeEvent(identifier: 1, kind: UInt32(kEventHotKeyPressed), signature: 0)
        precondition(registeredHotkeyHandler(nil, foreign, pointer) == OSStatus(eventNotHandledErr))
        ReleaseEvent(foreign)
        let unrelated = makeEvent(identifier: 1, kind: UInt32(kEventRawKeyDown))
        precondition(registeredHotkeyHandler(nil, unrelated, pointer) == OSStatus(eventNotHandledErr))
        ReleaseEvent(unrelated)
        precondition(registeredHotkeyHandler(nil, nil, pointer) == OSStatus(eventNotHandledErr))
        await drainQueue()
        precondition(received.count == 3, "Unrelated events must not reach the receiver")

        let stale = makeEvent(identifier: 2, kind: UInt32(kEventHotKeyReleased))
        precondition(registeredHotkeyHandler(nil, stale, pointer) == noErr)
        ReleaseEvent(stale)
        delivery.invalidate()
        await drainQueue()
        precondition(received.count == 3, "Stopping must discard already queued events")
        let afterStop = makeEvent(identifier: 1, kind: UInt32(kEventHotKeyPressed))
        precondition(registeredHotkeyHandler(nil, afterStop, pointer) == noErr)
        ReleaseEvent(afterStop)
        await drainQueue()
        precondition(received.count == 3, "Stopped receivers must stay inactive")
        print("6 isolated hotkey callback checks passed. No shortcuts registered, no events posted.")
    }

    private static func makeEvent(
        identifier: UInt32, kind: UInt32, signature: OSType = dictationHotkeySignature
    ) -> EventRef {
        var event: EventRef?
        precondition(CreateEvent(nil, OSType(kEventClassKeyboard), kind, 0, 0, &event) == noErr)
        guard let event else { preconditionFailure("Cannot allocate an in-memory event") }
        var value = EventHotKeyID(signature: signature, id: identifier)
        precondition(SetEventParameter(
            event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
            MemoryLayout<EventHotKeyID>.size, &value
        ) == noErr)
        return event
    }

    @MainActor
    private static func drainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}
