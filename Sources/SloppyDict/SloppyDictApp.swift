import AppKit
import FluidAudio
import SwiftUI

@main
struct SloppyDictApp {
    @MainActor
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.first == "--prepare-model", arguments.count == 2 {
            await runModelCommand(directory: URL(fileURLWithPath: arguments[1]), audio: nil, download: true)
            return
        }
        if arguments.first == "--transcribe", arguments.count == 3 {
            await runModelCommand(directory: URL(fileURLWithPath: arguments[1]),
                                  audio: URL(fileURLWithPath: arguments[2]), download: false)
            return
        }
        guard arguments.isEmpty else {
            fputs("Usage: SloppyDict [--prepare-model cache-directory | --transcribe cache-directory audio-file]\n", stderr)
            exit(2)
        }
        ModelHub.offlineMode = true
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
        withExtendedLifetime(delegate) {}
    }

    private static func runModelCommand(directory: URL, audio: URL?, download: Bool) async {
        do {
            let transcriber = Transcriber()
            let start = Date()
            let modelDirectory = directory.appendingPathComponent(Repo.parakeetUltra.folderName, isDirectory: true)
            try await transcriber.load(at: modelDirectory, download: download) { progress in
                switch progress.phase {
                case .listing: print("Listing model files")
                case .compiling(let name): print("Preparing \(name)")
                case .downloading: break
                }
            }
            print(String(format: "Model load: %.3f s; requested compute: CPU + Neural Engine", Date().timeIntervalSince(start)))
            if let audio {
                for index in 1...2 {
                    let started = Date()
                    let text = try await transcriber.transcribe(file: audio)
                    print(String(format: "Pass %d: %.3f s", index, Date().timeIntervalSince(started)))
                    print(text)
                }
            }
        } catch {
            fputs("SloppyDict: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let controller = AppController()
    private var statusItem: NSStatusItem?
    private var window: NSWindow?
    private var hud: HUDPresenter?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        hud = HUDPresenter(controller: controller)
        controller.onStatusChanged = { [weak self] in self?.refreshMenu() }
        refreshMenu()
        controller.start()
        if controller.needsSetup { showSettings() }
    }

    private func refreshMenu() {
        hud?.update(controller)
        let recording: Bool
        if case .recording = controller.phase { recording = true } else { recording = false }
        statusItem?.button?.image = NSImage(systemSymbolName: recording ? "record.circle.fill" : "mic", accessibilityDescription: controller.status)
        statusItem?.button?.contentTintColor = recording ? .systemRed : nil
        let menu = NSMenu()
        let status = menu.addItem(withTitle: controller.status, action: nil, keyEquivalent: "")
        status.isEnabled = false
        if recording {
            let stop = menu.addItem(withTitle: "Остановить запись", action: #selector(finish), keyEquivalent: "")
            stop.target = self
        }
        if controller.busy {
            let cancel = menu.addItem(withTitle: "Отменить диктовку", action: #selector(cancel), keyEquivalent: "")
            cancel.target = self
        }
        menu.addItem(.separator())
        let settings = menu.addItem(withTitle: "Настройки…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        let quit = menu.addItem(withTitle: "Выйти", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        statusItem?.menu = menu
    }

    @objc func showSettings() {
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView(controller: controller))
            let window = NSWindow(contentViewController: hosting)
            window.title = "SloppyDict"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    @objc private func finish() { controller.finishRecording() }
    @objc private func cancel() { controller.cancel() }
    @objc private func quit() { NSApp.terminate(nil) }

    func applicationWillTerminate(_ notification: Notification) {
        hud?.dismiss()
        controller.shutdown()
    }
}
