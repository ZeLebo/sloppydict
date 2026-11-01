import Carbon
import Foundation

let dictationHotkeySignature: OSType = 0x53444943 // SDIC

@MainActor
final class HotkeyEventDelivery {
    private var active = true
    private let handler: (UInt32, Bool) -> Void

    init(handler: @escaping (UInt32, Bool) -> Void) {
        self.handler = handler
    }

    func invalidate() { active = false }

    nonisolated func enqueue(identifier: UInt32, down: Bool) {
        // FIFO dispatch returns from Carbon before any microphone or UI work can run.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.active else { return }
            self.handler(identifier, down)
        }
    }
}

func registeredHotkeyHandler(
    _ handler: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData, GetEventClass(event) == OSType(kEventClassKeyboard) else {
        return OSStatus(eventNotHandledErr)
    }
    let kind = GetEventKind(event)
    guard kind == UInt32(kEventHotKeyPressed) || kind == UInt32(kEventHotKeyReleased) else {
        return OSStatus(eventNotHandledErr)
    }
    var identifier = EventHotKeyID()
    let status = GetEventParameter(
        event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
        nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier
    )
    guard status == noErr else { return status }
    guard identifier.signature == dictationHotkeySignature else { return OSStatus(eventNotHandledErr) }
    let delivery = Unmanaged<HotkeyEventDelivery>.fromOpaque(userData).takeUnretainedValue()
    delivery.enqueue(identifier: identifier.id, down: kind == UInt32(kEventHotKeyPressed))
    return noErr
}
