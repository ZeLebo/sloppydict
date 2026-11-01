import AppKit
import DictationCore
import SwiftUI

struct DictationNotice {
    enum Tone { case success, warning, error }
    let id = UUID()
    let title: String
    let detail: String
    let tone: Tone
}

struct DictationHUD: View {
    @ObservedObject var controller: AppController

    var body: some View {
        HStack(spacing: 12) {
            indicator.frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 12) {
                    Text(title).font(.system(size: 14, weight: .semibold))
                    if case .recording = controller.phase, let start = controller.recordingStartedAt {
                        Text(start, style: .timer).font(.system(size: 13, design: .monospaced))
                    }
                }
                Text(detail).font(.system(size: 11)).foregroundStyle(.white.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(minWidth: 240, maxWidth: 390, alignment: .leading)
        .background(Color(red: 0.10, green: 0.11, blue: 0.14), in: RoundedRectangle(cornerRadius: 18))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var indicator: some View {
        switch controller.phase {
        case .recording:
            Image(systemName: "record.circle.fill").font(.system(size: 22)).foregroundStyle(.red)
        case .transcribing:
            ProgressView().controlSize(.small).colorScheme(.dark)
        case .idle:
            if controller.cancelling {
                ProgressView().controlSize(.small).colorScheme(.dark)
            } else {
                Image(systemName: controller.notice?.tone == .success ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(controller.notice?.tone == .success ? .green : .orange)
            }
        }
    }

    private var title: String {
        if controller.cancelling { return "Отмена…" }
        switch controller.phase {
        case .recording: return "Запись"
        case .transcribing: return "Распознавание…"
        case .idle: return controller.notice?.title ?? "SloppyDict"
        }
    }

    private var detail: String {
        switch controller.phase {
        case .recording(.hold): return "Отпустите \(controller.shortcuts.hold.display) · Esc отменяет"
        case .recording(.toggle): return "\(controller.shortcuts.toggle.display) останавливает · Esc отменяет"
        case .transcribing: return "На этом Mac · без облака"
        case .idle: return controller.notice?.detail ?? ""
        }
    }
}

@MainActor
final class HUDPresenter {
    private let panel: HUDPanel
    private var hideTask: Task<Void, Never>?
    private var noticeID: UUID?

    init(controller: AppController) {
        panel = HUDPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: false)
        panel.contentView = NSHostingView(rootView: DictationHUD(controller: controller))
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.setAccessibilityLabel("Состояние диктовки SloppyDict")
    }

    func update(_ controller: AppController) {
        if controller.busy {
            hideTask?.cancel()
            noticeID = nil
            show()
        } else if let notice = controller.notice {
            guard notice.id != noticeID else { return }
            noticeID = notice.id
            hideTask?.cancel()
            show()
            hideTask = Task {
                do { try await Task.sleep(for: .seconds(notice.tone == .success ? 2 : 5)) }
                catch { return }
                panel.orderOut(nil)
            }
        } else {
            hideTask?.cancel()
            panel.orderOut(nil)
        }
    }

    func dismiss() {
        hideTask?.cancel()
        panel.orderOut(nil)
    }

    private func show() {
        guard let view = panel.contentView,
              let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main else { return }
        view.layoutSubtreeIfNeeded()
        let size = view.fittingSize
        panel.setContentSize(size)
        let frame = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.minY + 28))
        panel.orderFrontRegardless()
    }
}

private final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
