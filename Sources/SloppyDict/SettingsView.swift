import AppKit
import DictationCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var controller: AppController

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                Image(systemName: "waveform").font(.system(size: 28)).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text("SloppyDict").font(.title2.bold())
                    Text("Диктовка на этом Mac").foregroundStyle(.secondary)
                }
                Spacer()
                if controller.busy { ProgressView().controlSize(.small) }
            }

            VStack(alignment: .leading, spacing: 10) {
                Label(controller.status, systemImage: controller.ready ? "checkmark.circle" : "arrow.down.circle")
                    .font(.headline)
                if controller.ready {
                    Text(controller.modelStatus).font(.caption).foregroundStyle(.secondary)
                } else if controller.loading {
                    ProgressView()
                    Button("Отменить загрузку", action: controller.cancelModelLoad)
                } else {
                    Text("Parakeet Ultra · около 630 МБ · без облака")
                        .foregroundStyle(.secondary)
                    Button("Загрузить и подготовить модель") { controller.prepareModel(download: true) }
                        .buttonStyle(.borderedProminent)
                }
            }

            Divider()

            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 14) {
                GridRow {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Удержание")
                        Text("Отпустите, чтобы закончить запись").font(.caption).foregroundStyle(.secondary)
                    }
                    ShortcutRecorder(value: controller.shortcuts.hold, enabled: !controller.busy,
                                     onCapture: { controller.setShortcutCapture($0) },
                                     onChange: { controller.setShortcut($0, for: .hold) })
                        .frame(width: 160, height: 28)
                }
                GridRow {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Старт / стоп")
                        Text("Нажмите ещё раз, чтобы закончить").font(.caption).foregroundStyle(.secondary)
                    }
                    ShortcutRecorder(value: controller.shortcuts.toggle, enabled: !controller.busy,
                                     onCapture: { controller.setShortcutCapture($0) },
                                     onChange: { controller.setShortcut($0, for: .toggle) })
                        .frame(width: 160, height: 28)
                }
            }
            HStack {
                Text("Esc отменяет диктовку. Обычный пробел остаётся пробелом.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Сбросить", action: controller.resetShortcuts).controlSize(.small)
                    .disabled(controller.busy)
            }

            Picker("Язык", selection: $controller.language) {
                Text("Русский + English · экспериментальный").tag(DictationLanguage.mixed)
                Text("По текущей раскладке RU / EN").tag(DictationLanguage.inputSource)
                Text("Русский").tag(DictationLanguage.russian)
                Text("English").tag(DictationLanguage.english)
            }.disabled(controller.busy)

            Picker("Результат", selection: $controller.outputMode) {
                Text("Вставлять в исходное поле").tag(OutputMode.paste)
                Text("Только копировать в буфер").tag(OutputMode.clipboard)
            }.disabled(controller.busy)
            Text("Результат всегда остаётся в буфере обмена. Открывать это окно для вставки не нужно.")
                .font(.caption).foregroundStyle(.secondary)

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text(controller.accessStatus).font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Микрофон", action: controller.requestMicrophone)
                    Button("Универсальный доступ", action: controller.requestAccessibility)
                    Button("Проверить доступ", action: controller.refreshAccess)
                }.controlSize(.small).disabled(controller.busy)
            }

            if !controller.message.isEmpty {
                Text(controller.message).font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !controller.result.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Последний результат · только до следующей записи").font(.caption).foregroundStyle(.secondary)
                    ScrollView { Text(controller.result).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                        .frame(maxHeight: 110)
                    Button("Скопировать", action: controller.copyResult)
                }
            }
            if controller.busy {
                HStack {
                    if case .recording = controller.phase { Button("Остановить", action: controller.finishRecording) }
                    Button("Отменить диктовку", action: controller.cancel)
                }
            }
            Text("Аудио и история не сохраняются. После загрузки модели сеть не нужна.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 540)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct ShortcutRecorder: NSViewRepresentable {
    let value: Shortcut
    let enabled: Bool
    let onCapture: (Bool) -> Void
    let onChange: (Shortcut) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: value.display, target: context.coordinator, action: #selector(Coordinator.begin))
        button.bezelStyle = .rounded
        button.setAccessibilityLabel("Настроить сочетание \(value.display)")
        context.coordinator.button = button
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.parent = self
        button.isEnabled = enabled
        if context.coordinator.monitor == nil { button.title = value.display }
    }

    static func dismantleNSView(_ button: NSButton, coordinator: Coordinator) { coordinator.end() }

    @MainActor
    final class Coordinator: NSObject {
        var parent: ShortcutRecorder
        weak var button: NSButton?
        var monitor: Any?
        var resignObserver: NSObjectProtocol?
        var pendingShortcut: Shortcut?

        init(_ parent: ShortcutRecorder) { self.parent = parent }

        @objc func begin() {
            guard monitor == nil else { return }
            parent.onCapture(true)
            button?.title = "Нажмите сочетание…"
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
                let consumed = MainActor.assumeIsolated {
                    guard let self else { return false }
                    if event.type == .keyUp {
                        guard let pending = self.pendingShortcut, pending.keyCode == event.keyCode else { return true }
                        // Resume registrations after release, so capturing a held key cannot start dictation.
                        DispatchQueue.main.async { [weak self] in
                            guard let self, self.monitor != nil else { return }
                            self.end()
                            self.parent.onChange(pending)
                        }
                        return true
                    }
                    if event.keyCode == 53 { self.end(); return true }
                    let shortcut = Shortcut(keyCode: event.keyCode,
                                            modifiers: UInt64(event.modifierFlags.rawValue) & Shortcut.modifierMask)
                    guard shortcut.isValid else { return true }
                    self.pendingShortcut = shortcut
                    self.button?.title = "Отпустите \(shortcut.display)"
                    return true
                }
                return consumed ? nil : event
            }
            resignObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification, object: button?.window, queue: .main
            ) { [weak self] _ in Task { @MainActor in self?.end() } }
        }

        func end() {
            guard monitor != nil else { return }
            if let monitor { NSEvent.removeMonitor(monitor) }
            if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
            monitor = nil
            resignObserver = nil
            pendingShortcut = nil
            button?.title = parent.value.display
            parent.onCapture(false)
        }
    }
}
