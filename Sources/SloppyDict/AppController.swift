import AppKit
import AVFoundation
import Carbon
@preconcurrency import ApplicationServices
import DictationCore

@MainActor
final class AppController: ObservableObject {
    @Published private var machine = RecordingState()
    @Published private(set) var ready = false
    @Published private(set) var loading = false
    @Published private(set) var modelStatus = "Модель не загружена"
    @Published private(set) var accessStatus = "Проверьте разрешения"
    @Published private(set) var shortcuts = ShortcutPair()
    @Published var language = DictationLanguage.mixed {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: "language") }
    }
    @Published var outputMode = OutputMode.paste {
        didSet { UserDefaults.standard.set(outputMode.rawValue, forKey: "outputMode") }
    }
    @Published var hudStyle = HUDStyle.standard {
        didSet {
            UserDefaults.standard.set(hudStyle.rawValue, forKey: "hudStyle")
            onStatusChanged?()
        }
    }
    @Published var hudTextSize = HUDTextSize.standard {
        didSet {
            UserDefaults.standard.set(hudTextSize.rawValue, forKey: "hudTextSize")
            onStatusChanged?()
        }
    }
    @Published var showsLiveTranscript = false {
        didSet {
            UserDefaults.standard.set(showsLiveTranscript, forKey: "showsLiveTranscript")
            onStatusChanged?()
        }
    }
    @Published var finishOnEnter = false {
        didSet {
            UserDefaults.standard.set(finishOnEnter, forKey: "finishOnEnter")
            updateStatus()
        }
    }
    @Published private(set) var liveTranscript = ""
    @Published private(set) var liveTranscriptError = ""
    @Published private(set) var recordingStartedAt: Date?
    @Published private(set) var notice: DictationNotice?
    @Published var message = ""
    @Published var result = ""
    @Published private(set) var cancelling = false
    var onStatusChanged: (() -> Void)?
    let hotkeys = HotkeyMonitor()
    private let transcriber = Transcriber()
    private let recorder = AudioRecorder()
    private let liveTranscription = LiveTranscription()
    private var modelTask: Task<Void, Never>?
    private var transcriptionTask: Task<Void, Never>?
    private var session: UUID?
    private var target: TextTarget?
    private var sessionLanguage: String?
    private var sessionOutputMode = OutputMode.paste
    private var shortcutSettingsValid = true
    @Published private(set) var shortcutsReady = false
    private var observers: [NSObjectProtocol] = []

    var phase: RecordingPhase { machine.phase }
    var busy: Bool { phase != .idle || cancelling }
    var needsSetup: Bool {
        !Transcriber.isDownloaded() || !shortcutsReady
            || AVCaptureDevice.authorizationStatus(for: .audio) != .authorized
            || (outputMode == .paste && !AXIsProcessTrusted())
    }
    var status: String {
        if cancelling { return "Отмена распознавания…" }
        switch phase {
        case .idle: return ready ? "Готов к диктовке" : modelStatus
        case .recording: return "Идёт запись · максимум 2 минуты"
        case .transcribing: return "Распознавание на этом Mac…"
        }
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: "shortcuts") {
            do {
                let stored = try JSONDecoder().decode(ShortcutPair.self, from: data)
                guard stored.isValid else { throw DictationError.message("Некорректные сочетания.") }
                shortcuts = stored
            } catch {
                shortcutSettingsValid = false
                message = "Не удалось прочитать шорткаты. Назначьте их заново или сбросьте настройки сочетаний."
            }
        }
        if let value = UserDefaults.standard.string(forKey: "language"), let saved = DictationLanguage(rawValue: value) {
            language = saved
        }
        if let value = UserDefaults.standard.string(forKey: "outputMode"), let saved = OutputMode(rawValue: value) {
            outputMode = saved
        }
        if let value = UserDefaults.standard.string(forKey: "hudStyle"), let saved = HUDStyle(rawValue: value) {
            hudStyle = saved
        }
        if let saved = HUDTextSize(rawValue: UserDefaults.standard.double(forKey: "hudTextSize")) {
            hudTextSize = saved
        }
        showsLiveTranscript = UserDefaults.standard.bool(forKey: "showsLiveTranscript")
        finishOnEnter = UserDefaults.standard.bool(forKey: "finishOnEnter")
        hotkeys.shortcuts = shortcuts
        hotkeys.onKey = { [weak self] mode, down in self?.handle(mode, down: down) }
        hotkeys.onCancel = { [weak self] in self?.cancel() }
        hotkeys.onFinish = { [weak self] in
            guard let self else { return }
            self.perform(self.machine.finishWithEnter(enabled: self.finishOnEnter))
        }
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.cancel() }
            })
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, case .recording = self.phase else { return }
                self.cancel()
                self.presentNotice("Запись остановлена", detail: "Аудиоустройство изменилось. Начните диктовку заново.", tone: .error)
            }
        })
    }

    func start() {
        refreshAccess()
        if Transcriber.isDownloaded() { prepareModel(download: false) }
    }

    func refreshAccess() {
        cancel()
        hotkeys.stop()
        shortcutsReady = false
        let microphone = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        let accessibility = AXIsProcessTrusted()
        accessStatus = "Микрофон: \(microphone ? "разрешён" : "нет доступа") · автовставка: \(accessibility ? "разрешена" : "нет доступа")"
        guard shortcutSettingsValid else { return }
        do { try hotkeys.start(); shortcutsReady = true }
        catch { message = error.localizedDescription }
        updateStatus()
    }

    func setShortcutCapture(_ active: Bool) {
        if active {
            cancel()
            hotkeys.stop()
            shortcutsReady = false
        } else { refreshAccess() }
    }

    func requestMicrophone() {
        Task {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
            refreshAccess()
        }
    }

    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        refreshAccess()
    }

    func prepareModel(download: Bool) {
        guard !loading, !ready else { return }
        loading = true
        message = ""
        modelStatus = download ? "Загрузка Parakeet Ultra…" : "Подготовка Parakeet Ultra…"
        modelTask = Task { [self] in
            do {
                try await transcriber.load(download: download) { [weak self] progress in
                    Task { @MainActor in
                        guard let self, self.loading else { return }
                        switch progress.phase {
                        case .listing: self.modelStatus = "Проверка файлов модели…"
                        case .downloading:
                            self.modelStatus = "Загрузка текущего компонента: \(Int(progress.fractionCompleted * 100))%"
                        case .compiling: self.modelStatus = "Подготовка модели для Core ML…"
                        }
                    }
                }
                try Task.checkCancellation()
                ready = true
                modelStatus = "Parakeet Ultra · локально · CPU + Neural Engine"
            } catch is CancellationError {
                modelStatus = "Загрузка отменена"
            } catch {
                modelStatus = "Модель недоступна"
                message = error.localizedDescription
            }
            loading = false
            modelTask = nil
            updateStatus()
        }
    }

    func cancelModelLoad() { modelTask?.cancel() }

    func setShortcut(_ value: Shortcut, for mode: RecordingMode) {
        var next = shortcuts
        if mode == .hold { next.hold = value } else { next.toggle = value }
        guard next.isValid else {
            message = "Выберите разные сочетания с Control, Option, Shift или Command."
            return
        }
        do {
            let data = try JSONEncoder().encode(next)
            shortcuts = next
            hotkeys.shortcuts = next
            UserDefaults.standard.set(data, forKey: "shortcuts")
            shortcutSettingsValid = true
            message = ""
            refreshAccess()
        } catch { message = error.localizedDescription }
    }

    func resetShortcuts() {
        shortcuts = ShortcutPair()
        hotkeys.shortcuts = shortcuts
        shortcutSettingsValid = true
        UserDefaults.standard.removeObject(forKey: "shortcuts")
        message = ""
        refreshAccess()
    }

    private func handle(_ mode: RecordingMode, down: Bool) {
        guard !cancelling else { return }
        if phase == .idle {
            guard down else { return }
            guard ready else {
                presentNotice("Модель не готова", detail: loading ? "Дождитесь подготовки модели." : "Загрузите Parakeet Ultra в настройках.", tone: .warning)
                return
            }
            guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
                presentNotice("Нет доступа к микрофону", detail: "Разрешите микрофон в настройках SloppyDict.", tone: .error)
                return
            }
        }
        let effect = down ? machine.press(mode) : machine.release(mode)
        perform(effect)
    }

    func finishRecording() { perform(machine.finish()) }

    private func perform(_ effect: RecordingEffect?) {
        guard let effect else { return }
        switch effect {
        case .start:
            do {
                let languages = Self.currentInputLanguages()
                sessionLanguage = language.resolved(inputLanguages: languages)
                if language == .inputSource, sessionLanguage == nil {
                    throw DictationError.message("Источник ввода не относится к RU/EN. Выберите русский или английский вручную.")
                }
                target = TextTarget.capture()
                sessionOutputMode = outputMode
                let id = UUID()
                session = id
                result = ""
                liveTranscript = ""
                liveTranscriptError = ""
                message = ""
                notice = nil
                recordingStartedAt = Date()
                try hotkeys.setCancellationEnabled(true)
                try hotkeys.setFinishingEnabled(finishOnEnter && phase == .recording(.toggle))
                try recorder.start(onLimit: { [weak self] in
                    Task { @MainActor in
                        guard let self, self.session == id, case .recording = self.phase else { return }
                        self.finishRecording()
                    }
                }, onError: { [weak self] error in
                    Task { @MainActor in
                        guard let self, self.session == id, case .recording = self.phase else { return }
                        self.cancel()
                        self.presentNotice("Ошибка записи", detail: error, tone: .error)
                    }
                })
                if showsLiveTranscript { startLiveTranscription(session: id) }
            } catch {
                recorder.stop()
                machine.complete()
                recordingStartedAt = nil
                session = nil
                presentNotice("Не удалось начать запись", detail: error.localizedDescription, tone: .error)
            }
        case .finish:
            let preview = liveTranscription.stop()
            let samples = recorder.stop()
            recordingStartedAt = nil
            let id = session
            let target = target
            let hint = sessionLanguage
            let output = sessionOutputMode
            transcriptionTask = Task {
                await preview?.value
                do {
                    try Task.checkCancellation()
                    if samples.count >= 3200,
                       samples.allSatisfy(\.isFinite),
                       samples.contains(where: { abs($0) > 0.0001 }) {
                        let text = try await transcriber.transcribe(samples, language: hint)
                        try Task.checkCancellation()
                        guard session == id else { throw CancellationError() }
                        result = text
                        if !text.isEmpty {
                            switch try TextDelivery.deliver(text, mode: output, target: target) {
                            case .copied:
                                presentNotice("Скопировано", detail: "Нажмите ⌘V, чтобы вставить текст.", tone: .success)
                            case .pasteRequested:
                                presentNotice("Готово", detail: "Текст также в буфере обмена.", tone: .success)
                            case .copiedForManualPaste(let reason):
                                presentNotice("Скопировано", detail: reason, tone: .warning)
                            }
                        } else { presentNotice("Речь не распознана", detail: "Попробуйте записать фразу ещё раз.", tone: .warning) }
                    } else {
                        presentNotice("Речь не обнаружена", detail: "Запись слишком короткая или тихая.", tone: .warning)
                    }
                } catch is CancellationError {
                    presentNotice("Отменено", detail: "Результат не скопирован и не вставлен.", tone: .warning)
                } catch {
                    presentNotice("Ошибка диктовки", detail: error.localizedDescription, tone: .error)
                }
                machine.complete()
                session = nil
                self.target = nil
                liveTranscript = ""
                liveTranscriptError = ""
                transcriptionTask = nil
                cancelling = false
                updateStatus()
            }
        case .cancel: break
        }
        updateStatus()
    }

    private func startLiveTranscription(session id: UUID) {
        let transcriber = transcriber
        let hint = sessionLanguage
        liveTranscription.start(snapshot: { [weak self] in
            guard let self, self.session == id, case .recording = self.phase else { return [] }
            return self.recorder.previewSamples()
        }, transcribe: { samples in
            try await transcriber.transcribe(samples, language: hint)
        }, update: { [weak self] update in
            guard let self, self.session == id, case .recording = self.phase else { return }
            switch update {
            case .success(let text): self.liveTranscript = text
            case .failure(let error): self.liveTranscriptError = error.localizedDescription
            }
        })
    }

    func cancel() {
        guard machine.cancel() != nil else { return }
        let preview = liveTranscription.stop()
        recorder.stop()
        recordingStartedAt = nil
        session = nil
        target = nil
        result = ""
        liveTranscript = ""
        liveTranscriptError = ""
        if let transcriptionTask {
            cancelling = true
            transcriptionTask.cancel()
        } else if let preview {
            cancelling = true
            transcriptionTask = Task {
                await preview.value
                transcriptionTask = nil
                cancelling = false
                updateStatus()
            }
        }
        presentNotice("Отменено", detail: "Результат не скопирован и не вставлен.", tone: .warning)
    }

    func copyResult() {
        do {
            try TextDelivery.copy(result)
            presentNotice("Скопировано", detail: "Нажмите ⌘V, чтобы вставить текст.", tone: .success)
        } catch { presentNotice("Не удалось скопировать", detail: error.localizedDescription, tone: .error) }
    }

    private func presentNotice(_ title: String, detail: String, tone: DictationNotice.Tone) {
        notice = DictationNotice(title: title, detail: detail, tone: tone)
        message = tone == .success ? "" : detail
        updateStatus()
    }

    private func updateStatus() {
        do {
            try hotkeys.setCancellationEnabled(phase != .idle)
            try hotkeys.setFinishingEnabled(finishOnEnter && phase == .recording(.toggle))
        }
        catch {
            cancel()
            notice = DictationNotice(title: "Шорткат недоступен", detail: error.localizedDescription, tone: .error)
            message = error.localizedDescription
        }
        onStatusChanged?()
    }

    func shutdown() {
        onStatusChanged = nil
        cancel()
        modelTask?.cancel()
        hotkeys.stop()
    }

    private static func currentInputLanguages() -> [String] {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages) else { return [] }
        return Unmanaged<CFArray>.fromOpaque(pointer).takeUnretainedValue() as? [String] ?? []
    }
}
