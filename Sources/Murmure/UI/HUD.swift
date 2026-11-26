import AppKit
import SwiftUI

/// État partagé entre le contrôleur et la vue : sert à animer l'entrée et la sortie.
@MainActor
final class HUDModel: ObservableObject {
    @Published var visible = false
}

/// Indicateur de dictée qui sort de l'encoche du Mac (ou du haut de l'écran sans encoche).
/// Il ne prend jamais le focus et laisse passer les clics : l'utilisateur reste dans son app.
@MainActor
final class HUDController {
    private weak var controller: AppController?
    private var panel: NSPanel?
    private let model = HUDModel()
    private var hideWork: DispatchWorkItem?
    static let width: CGFloat = 440

    init(controller: AppController) { self.controller = controller }

    func show() {
        hideWork?.cancel()
        let panel = self.panel ?? makePanel()
        self.panel = panel
        position(panel)
        panel.alphaValue = 1
        if !panel.isVisible { panel.orderFrontRegardless() }
        withAnimation(Theme.reduceMotion ? .easeOut(duration: 0.15) : .spring(duration: 0.35, bounce: 0)) {
            model.visible = true
        }
    }

    func hide(after delay: TimeInterval = 0) {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            withAnimation(Theme.reduceMotion ? .easeOut(duration: 0.12) : .spring(duration: 0.25, bounce: 0)) {
                self.model.visible = false
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, !self.model.visible else { return }
                self.panel?.orderOut(nil)
                self.controller?.resetIfFinished()
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 90),
                            styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        // Au-dessus de la barre des menus, pour se fondre dans l'encoche.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        return panel
    }

    /// Centré en haut de l'écran où se trouve la souris, collé au bord supérieur.
    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main,
              let controller else { return }
        let top = screen.safeAreaInsets.top
        var notchWidth: CGFloat = 0
        if top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            notchWidth = screen.frame.width - left.width - right.width
        }
        let height = top + 34 + 24
        let frame = NSRect(x: screen.frame.midX - Self.width / 2, y: screen.frame.maxY - height,
                           width: Self.width, height: height)
        panel.setFrame(frame, display: false)
        let root = HUDView(model: model, notchHeight: top, notchWidth: notchWidth).environmentObject(controller)
        if let host = panel.contentView as? NSHostingView<AnyView> {
            host.rootView = AnyView(root)
        } else {
            let host = NSHostingView(rootView: AnyView(root))
            host.frame = NSRect(origin: .zero, size: frame.size)
            host.autoresizingMask = [.width, .height]
            panel.contentView = host
        }
    }
}

struct HUDView: View {
    @EnvironmentObject var app: AppController
    @ObservedObject var model: HUDModel
    let notchHeight: CGFloat
    let notchWidth: CGFloat

    private let row: CGFloat = 34

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                content
            }
            .id(phaseKey)
            .transition(Theme.reduceMotion ? .opacity
                        : .opacity.combined(with: .modifier(active: BlurModifier(radius: 3), identity: BlurModifier(radius: 0))))
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Color.white)
            .padding(.horizontal, 18)
            .frame(minWidth: notchWidth > 0 ? notchWidth + 28 : 0)
            .frame(height: row)
            .padding(.top, notchHeight)
            .background(
                UnevenRoundedRectangle(bottomLeadingRadius: 16, bottomTrailingRadius: 16, style: .continuous)
                    .fill(Color.black)
                    .shadow(color: .black.opacity(0.28), radius: 12, y: 6)
            )
            .opacity(model.visible ? 1 : 0)
            .scaleEffect(x: model.visible ? 1 : 0.7, y: model.visible ? 1 : 0.4, anchor: .top)
            .animation(Theme.reduceMotion ? .easeOut(duration: 0.15) : .spring(duration: 0.35, bounce: 0), value: phaseKey)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
    }

    private var phaseKey: String {
        switch app.phase {
        case .idle: return "idle"
        case .recording(let free): return free ? "free" : "hold"
        case .transcribing, .polishing: return "polishing"
        case .translating: return "translating"
        case .done: return "done"
        case .failed: return "failed"
        }
    }

    @ViewBuilder
    private var content: some View {
        switch app.phase {
        case .recording(let handsFree):
            Waveform(level: app.level, active: true)
            Text(handsFree ? "J'écoute · mains libres" : "J'écoute")
        case .transcribing, .polishing:
            Image(systemName: "text.alignleft").font(.system(size: 12, weight: .semibold))
            Text("Mise au propre")
        case .translating(let language):
            Image(systemName: "globe").font(.system(size: 12, weight: .semibold))
            Text("Traduction en \(language.lowercased())")
        case .done(let label):
            Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(Color(red: 0.42, green: 0.84, blue: 0.57))
            Text(label)
        case .failed(let message):
            Image(systemName: "exclamationmark.circle").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.wave)
            Text("Erreur")
            Rectangle().fill(Color.white.opacity(0.25)).frame(width: 1, height: 14)
            Text(message).foregroundStyle(Color.white.opacity(0.65)).lineLimit(1).frame(maxWidth: 260)
        case .idle:
            EmptyView()
        }
    }
}

/// Barres qui suivent la voix. Au repos (transcription), une vague lente les parcourt.
struct Waveform: View {
    let level: Float
    let active: Bool
    var color: Color = Theme.wave
    private let bars = 9
    /// Profil en cloche : les barres centrales réagissent plus fort.
    private let profile: [CGFloat] = [0.35, 0.55, 0.75, 0.9, 1, 0.9, 0.75, 0.55, 0.35]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: Theme.reduceMotion)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<bars, id: \.self) { i in
                    Capsule()
                        .fill(active ? color : Color.white.opacity(0.55))
                        .frame(width: 2.5, height: height(i, t))
                }
            }
            .frame(height: 18)
        }
    }

    private func height(_ i: Int, _ t: TimeInterval) -> CGFloat {
        let minH: CGFloat = 3
        if active {
            let jitter = CGFloat(0.75 + 0.25 * sin(t * 13 + Double(i) * 1.7))
            return minH + CGFloat(level) * 15 * profile[i] * jitter
        }
        if Theme.reduceMotion { return 6 }
        let wave = (sin(t * 5 - Double(i) * 0.7) + 1) / 2
        return minH + CGFloat(wave) * 8
    }
}
