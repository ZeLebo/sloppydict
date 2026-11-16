import AppKit
import DictationCore
import SwiftUI

enum HUDStyle: String, CaseIterable {
    case standard, minimalist

    var title: String {
        switch self {
        case .standard: return "Стандартный"
        case .minimalist: return "Минималистичный"
        }
    }
}

enum HUDTextSize: Double, CaseIterable {
    case small = 12, standard = 14, large = 16, larger = 18, extraLarge = 20, largest = 24

    var title: String { "\(Int(rawValue)) pt" }
}

struct DictationNotice {
    enum Tone { case success, warning, error }
    let id = UUID()
    let title: String
    let detail: String
    let tone: Tone
}

struct DictationHUD: View {
    @ObservedObject var controller: AppController

    private var fontSize: CGFloat { controller.hudTextSize.rawValue }
    private var isMinimalist: Bool { controller.hudStyle == .minimalist }

    var body: some View {
        VStack(spacing: 8) {
            if controller.showsLiveTranscript, controller.phase != .idle {
                HUDTextLayout {
                    Text(previewText)
                        .font(.system(size: fontSize)).lineLimit(3).truncationMode(.head)
                }
                .padding(10)
                .background(HUDSurface(radius: 12))
            }
            if controller.phase == .idle, let notice = controller.notice, notice.tone != .success {
                HUDTextLayout {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(notice.title).font(.system(size: fontSize, weight: .semibold))
                        Text(notice.detail).font(.system(size: fontSize)).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(12)
                .background(HUDSurface(radius: 12))
            }
            HStack(spacing: isMicro ? 8 : 10) {
                indicator.frame(width: isMicro ? 11 : 14, height: 14)
                    .accessibilityLabel(title).accessibilityHidden(!isMicro)
                if !isMicro {
                    Text(title).font(.system(size: fontSize, weight: .medium)).lineLimit(1)
                        .frame(maxWidth: 360)
                }
                if case .recording = controller.phase, let start = controller.recordingStartedAt {
                    if !isMicro {
                        Image(systemName: "waveform").font(.system(size: 12)).accessibilityHidden(true)
                    }
                    Text(start, style: .timer).monospacedDigit()
                        .font(.system(size: fontSize)).fixedSize()
                    if !isMicro, controller.finishOnEnter, controller.phase == .recording(.toggle) {
                        Text("↵").font(.system(size: fontSize))
                    }
                }
            }
            .padding(.horizontal, isMinimalist ? 10 : 16)
            .padding(.vertical, isMinimalist ? 6 : 10)
            .fixedSize()
            .background(HUDSurface(radius: 1000))
        }
        .foregroundStyle(.white)
        .colorScheme(.dark)
        .fixedSize()
        .accessibilityElement(children: .combine)
        .accessibilityHint(detail)
    }

    private var isMicro: Bool {
        if case .recording = controller.phase { return controller.hudStyle == .minimalist }
        return false
    }

    private var previewText: String {
        if !controller.liveTranscriptError.isEmpty { return controller.liveTranscriptError }
        return controller.liveTranscript.isEmpty ? "Речь появится здесь…" : controller.liveTranscript
    }

    @ViewBuilder private var indicator: some View {
        switch controller.phase {
        case .recording:
            Image(systemName: isMicro ? "waveform" : "mic.fill")
                .font(.system(size: isMicro ? 11 : 14))
                .foregroundStyle(isMicro ? .white : Color(red: 0.95, green: 0.62, blue: 0.50))
        case .transcribing:
            ProgressView().controlSize(.mini)
        case .idle:
            if controller.cancelling {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: controller.notice?.tone == .success ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.system(size: 13))
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
        case .recording(.toggle):
            return "\(controller.finishOnEnter ? "Enter или " : "")\(controller.shortcuts.toggle.display) останавливает · Esc отменяет"
        case .transcribing: return "На этом Mac · без облака"
        case .idle: return controller.notice?.detail ?? ""
        }
    }
}

// Constrain width before measuring height so multiline text wraps inside an intrinsic-size panel.
private struct HUDTextLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let width = min(360, content.sizeThatFits(.unspecified).width)
        let size = content.sizeThatFits(ProposedViewSize(width: width, height: nil))
        return CGSize(width: width, height: size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: nil))
    }
}

final class HUDHostingView: NSHostingView<DictationHUD> {
    var onSizeChange: ((CGSize) -> Void)?
    private var reportedSize = CGSize.zero

    convenience init(controller: AppController) {
        self.init(rootView: DictationHUD(controller: controller))
        // The presenter owns the window frame; SwiftUI must not change its min/max size.
        sizingOptions = [.intrinsicContentSize]
    }

    override func layout() {
        super.layout()
        let size = fittingSize
        guard size != reportedSize else { return }
        reportedSize = size
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onSizeChange?(self.fittingSize)
        }
    }
}

func hudFrame(contentSize: CGSize, visibleFrame: CGRect) -> CGRect? {
    guard contentSize.width.isFinite, contentSize.height.isFinite,
          contentSize.width > 0, contentSize.height > 0 else { return nil }
    let size = CGSize(width: ceil(contentSize.width), height: ceil(contentSize.height))
    return CGRect(x: visibleFrame.midX - size.width / 2, y: visibleFrame.minY + 28,
                  width: size.width, height: size.height)
}

private struct HUDSurface: View {
    let radius: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            if !reduceTransparency { HUDMaterial(radius: radius) }
            Color(red: 0.14, green: 0.16, blue: 0.19).opacity(reduceTransparency ? 1 : 0.35)
        }
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(.white.opacity(0.12)))
    }
}

private final class HUDVisualEffectView: NSVisualEffectView {
    var radius: CGFloat = 0

    override func layout() {
        super.layout()
        layer?.cornerRadius = min(radius, bounds.width / 2, bounds.height / 2)
    }
}

private struct HUDMaterial: NSViewRepresentable {
    let radius: CGFloat

    func makeNSView(context: Context) -> HUDVisualEffectView {
        let view = HUDVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .vibrantDark)
        view.wantsLayer = true
        view.layer?.masksToBounds = true
        return view
    }

    func updateNSView(_ view: HUDVisualEffectView, context: Context) {
        view.radius = radius
        view.needsLayout = true
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
        let content = HUDHostingView(controller: controller)
        content.onSizeChange = { [weak self] size in
            self?.contentSizeChanged(size)
        }
        panel.contentView = content
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
            guard notice.id != noticeID else {
                if panel.isVisible { show() }
                return
            }
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
              let screen = (panel.isVisible ? panel.screen : nil)
                ?? NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main else { return }
        view.layoutSubtreeIfNeeded()
        place(size: view.fittingSize, on: screen)
        panel.orderFrontRegardless()
    }

    private func contentSizeChanged(_ size: CGSize) {
        guard panel.isVisible, let screen = panel.screen else { return }
        place(size: size, on: screen)
    }

    private func place(size: CGSize, on screen: NSScreen) {
        guard let frame = hudFrame(contentSize: size, visibleFrame: screen.visibleFrame) else { return }
        panel.setFrame(frame, display: true)
    }
}

private final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
