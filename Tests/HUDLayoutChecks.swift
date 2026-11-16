import AppKit
import DictationCore
import SwiftUI

// Presentation-only state: no application startup, microphone, clipboard or hotkey registration.
@MainActor
final class AppController: ObservableObject {
    @Published var phase = RecordingPhase.idle
    @Published var hudStyle = HUDStyle.standard
    @Published var hudTextSize = HUDTextSize.standard
    @Published var showsLiveTranscript = false
    @Published var liveTranscript = ""
    @Published var liveTranscriptError = ""
    @Published var notice: DictationNotice? = DictationNotice(title: "Готово", detail: "Текст в буфере обмена.", tone: .success)
    @Published var cancelling = false
    @Published var finishOnEnter = false
    @Published var recordingStartedAt: Date?
    let shortcuts = ShortcutPair()
    var busy: Bool { phase != .idle || cancelling }
}

@main
struct HUDLayoutChecks {
    @MainActor private static var scenarios = 0

    @MainActor
    private static func measure(_ controller: AppController) -> CGSize {
        let renderer = ImageRenderer(content: DictationHUD(controller: controller))
        guard let image = renderer.nsImage else { preconditionFailure("Offscreen HUD rendering failed") }
        scenarios += 1
        return image.size
    }

    @MainActor
    private static func checkHostingUpdates() {
        let screens = [
            CGRect(x: 0, y: 48, width: 1440, height: 852),
            CGRect(x: -1920, y: -300, width: 1920, height: 1080),
            CGRect(x: 1440, y: 900, width: 1728, height: 1050),
        ]
        for style in HUDStyle.allCases {
            for textSize in [HUDTextSize.standard, .largest] {
                let state = AppController()
                state.hudStyle = style
                state.hudTextSize = textSize
                state.phase = .recording(.toggle)
                state.recordingStartedAt = Date().addingTimeInterval(-15)
                state.showsLiveTranscript = true
                let host = HUDHostingView(controller: state)
                precondition(host.sizingOptions == [.intrinsicContentSize], "Only the presenter may resize the window")
                var reportedSize: CGSize?
                host.onSizeChange = { size in
                    reportedSize = size
                    host.setFrameSize(size)
                }
                host.setFrameSize(host.fittingSize)
                for text in ["Да.", String(repeating: "Проверяем перенос строки. ", count: 3),
                             String(repeating: "Проверяем перенос строки. ", count: 12), "Да."] {
                    state.liveTranscript = text
                    for _ in 0..<5 {
                        host.needsLayout = true
                        host.layoutSubtreeIfNeeded()
                        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
                    }
                    precondition(reportedSize == host.fittingSize, "AppKit must receive the latest content size")
                    for screen in screens {
                        let frame = hudFrame(contentSize: host.fittingSize, visibleFrame: screen)!
                        precondition(frame.midX == screen.midX, "Growing text must stay centered")
                        precondition(frame.minY == screen.minY + 28, "Growing text must keep the bottom offset")
                        precondition(screen.contains(frame), "HUD must remain inside the visible screen")
                    }
                    scenarios += 1
                }
                host.onSizeChange = nil
            }
        }
    }

    @MainActor
    static func main() {
        checkHostingUpdates()
        for style in HUDStyle.allCases {
            var previousWidth: CGFloat = 0
            for textSize in HUDTextSize.allCases {
                let state = AppController()
                state.hudStyle = style
                state.hudTextSize = textSize
                let size = measure(state)
                let points = textSize.rawValue
                let textWidth = ("Готово" as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: points, weight: .medium)]).width
                precondition(size.width <= textWidth + 68, "Short success must fit its content, without a fixed-width capsule")
                precondition(size.height >= points + 10 && size.height <= points + 28, "Font must fit without excessive vertical space")
                precondition(size.width > previousWidth, "Larger type must grow the capsule")
                previousWidth = size.width

                state.phase = .transcribing
                let processing = measure(state)
                precondition(processing.width > size.width && processing.width < 400, "Longer status must adapt its width")

                state.phase = .recording(.toggle)
                state.recordingStartedAt = Date().addingTimeInterval(-15)
                let recording = measure(state)
                precondition(recording.height >= points + 10 && recording.width < 450)
            }

            for textSize in [HUDTextSize.standard, .largest] {
                let state = AppController()
                state.hudStyle = style
                state.hudTextSize = textSize
                state.phase = .recording(.toggle)
                state.recordingStartedAt = Date().addingTimeInterval(-15)
                state.showsLiveTranscript = true
                state.liveTranscript = "Да."
                let short = measure(state)
                state.liveTranscript = String(repeating: "Длинная фраза для проверки переноса текста. ", count: 8)
                let long = measure(state)
                precondition(long.height > short.height, "Transcript must grow naturally: \(style.rawValue) \(short) -> \(long)")
                precondition(long.width <= 400 && long.height < 240)

                state.phase = .idle
                state.notice = DictationNotice(title: "В буфере", detail: "Текст скопирован.", tone: .warning)
                let shortNotice = measure(state)
                state.notice = DictationNotice(title: "В буфере", detail: "Исходное поле больше недоступно. Текст остался в буфере обмена, его можно вставить вручную.", tone: .warning)
                let longNotice = measure(state)
                precondition(longNotice.height > shortNotice.height && longNotice.width <= 400, "Notice must wrap without clipping")
            }
        }
        print("\(scenarios) offscreen SwiftUI/AppKit layout scenarios passed. No windows, microphone or hotkeys used.")
    }
}
