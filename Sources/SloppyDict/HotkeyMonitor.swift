import Carbon
import DictationCore

@MainActor
final class HotkeyMonitor {
    var shortcuts = ShortcutPair()
    var onKey: ((RecordingMode, Bool) -> Void)?
    var onCancel: (() -> Void)?
    var onFinish: (() -> Void)?
    private enum Action { case key(RecordingMode), cancel, finish }
    private var eventHandler: EventHandlerRef?
    private var delivery: HotkeyEventDelivery?
    private var registrations: [UInt32: (reference: EventHotKeyRef, action: Action, keyCode: UInt16)] = [:]
    private var cancelIdentifier: UInt32?
    private var finishing = FinishingHotkeys()
    private var nextIdentifier: UInt32 = 0
    private var pressed: Set<UInt32> = []

    func start() throws {
        stop()
        guard shortcuts.isValid else {
            throw DictationError.message("Назначьте два разных сочетания с модификаторами.")
        }
        let delivery = HotkeyEventDelivery { [weak self] identifier, down in
            self?.receive(identifier, down: down)
        }
        self.delivery = delivery
        var events = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let status = InstallEventHandler(
            GetApplicationEventTarget(), registeredHotkeyHandler, events.count, &events,
            Unmanaged.passUnretained(delivery).toOpaque(), &eventHandler
        )
        guard status == noErr, eventHandler != nil else {
            stop()
            throw DictationError.message("Не удалось подключить шорткаты (OSStatus \(status)).")
        }
        do {
            _ = try register(shortcuts.hold, action: .key(.hold))
            _ = try register(shortcuts.toggle, action: .key(.toggle))
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        delivery?.invalidate()
        for registration in registrations.values { UnregisterEventHotKey(registration.reference) }
        registrations.removeAll()
        cancelIdentifier = nil
        finishing = FinishingHotkeys()
        if let eventHandler { RemoveEventHandler(eventHandler) }
        eventHandler = nil
        delivery = nil
        pressed.removeAll()
    }

    func setCancellationEnabled(_ enabled: Bool) throws {
        if enabled {
            guard cancelIdentifier == nil else { return }
            guard eventHandler != nil else { throw DictationError.message("Шорткаты не подключены.") }
            cancelIdentifier = try register(Shortcut(keyCode: UInt16(kVK_Escape), modifiers: 0), action: .cancel)
        } else if let identifier = cancelIdentifier {
            unregister(identifier)
            cancelIdentifier = nil
        }
    }

    func setFinishingEnabled(_ enabled: Bool) throws {
        guard enabled != finishing.enabled else { return }
        if enabled {
            guard eventHandler != nil else { throw DictationError.message("Шорткаты не подключены.") }
            var added: Set<UInt32> = []
            do {
                for key in [UInt16(kVK_Return), UInt16(kVK_ANSI_KeypadEnter)] {
                    // A press from a cancelled session must finish releasing before it can finish a new one.
                    guard !finishing.retiring.contains(where: { registrations[$0]?.keyCode == key }) else { continue }
                    added.insert(try register(Shortcut(keyCode: key, modifiers: 0), action: .finish))
                }
            } catch {
                for identifier in added { unregister(identifier) }
                throw error
            }
            finishing.activate(added)
        } else {
            for identifier in finishing.deactivate(pressed: pressed) { unregister(identifier) }
        }
    }

    private func unregister(_ identifier: UInt32) {
        if let registration = registrations.removeValue(forKey: identifier) {
            UnregisterEventHotKey(registration.reference)
        }
        pressed.remove(identifier)
    }

    private func register(_ shortcut: Shortcut, action: Action) throws -> UInt32 {
        nextIdentifier += 1
        let identifier = nextIdentifier
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(shortcut.keyCode), shortcut.carbonModifiers,
            EventHotKeyID(signature: dictationHotkeySignature, id: identifier),
            GetApplicationEventTarget(), UInt32(kEventHotKeyExclusive), &reference
        )
        guard status == noErr, let reference else {
            if case .cancel = action {
                throw DictationError.message("Не удалось подключить Esc для отмены (OSStatus \(status)). Диктовка остановлена.")
            }
            if case .finish = action {
                throw DictationError.message("Не удалось подключить Enter для завершения (OSStatus \(status)). Диктовка остановлена.")
            }
            throw DictationError.message("Не удалось зарегистрировать \(shortcut.display). Выберите свободное сочетание (OSStatus \(status)).")
        }
        registrations[identifier] = (reference, action, shortcut.keyCode)
        return identifier
    }

    private func receive(_ identifier: UInt32, down: Bool) {
        guard let registration = registrations[identifier] else { return }
        if down {
            guard pressed.insert(identifier).inserted else { return }
        } else {
            guard pressed.remove(identifier) != nil else { return }
        }
        switch registration.action {
        case .key(let mode): onKey?(mode, down)
        case .cancel: if down { onCancel?() }
        case .finish:
            guard !down else { return }
            // Finish on release, keeping the entire Enter press and its repeats out of the target app.
            switch finishing.release(identifier) {
            case .finish: onFinish?()
            case .unregister: unregister(identifier)
            case .keepRegistered, .ignore: break
            }
        }
    }
}

extension Shortcut {
    var display: String {
        var text = ""
        if modifiers & (1 << 18) != 0 { text += "⌃" }
        if modifiers & (1 << 19) != 0 { text += "⌥" }
        if modifiers & (1 << 17) != 0 { text += "⇧" }
        if modifiers & (1 << 20) != 0 { text += "⌘" }
        let names: [UInt16: String] = [
            0:"A", 1:"S", 2:"D", 3:"F", 4:"H", 5:"G", 6:"Z", 7:"X", 8:"C", 9:"V",
            11:"B", 12:"Q", 13:"W", 14:"E", 15:"R", 16:"Y", 17:"T", 18:"1", 19:"2",
            20:"3", 21:"4", 22:"6", 23:"5", 24:"=", 25:"9", 26:"7", 27:"−", 28:"8",
            29:"0", 30:"]", 31:"O", 32:"U", 33:"[", 34:"I", 35:"P", 36:"Return", 37:"L",
            38:"J", 39:"'", 40:"K", 41:";", 42:"\\", 43:",", 44:"/", 45:"N", 46:"M",
            47:".", 48:"Tab", 49:"Space", 50:"`", 51:"Delete", 53:"Esc", 123:"←", 124:"→",
            125:"↓", 126:"↑", 122:"F1", 120:"F2", 99:"F3", 118:"F4", 96:"F5", 97:"F6",
            98:"F7", 100:"F8", 101:"F9", 109:"F10", 103:"F11", 111:"F12",
        ]
        return text + (names[keyCode] ?? "Key \(keyCode)")
    }
}
