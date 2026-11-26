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
    static let width: CGFloat = 560

    init(controller: AppController) { self.controller = controller }

    /// Crée la fenêtre et sa vue à l'avance : le premier appui n'a plus à les construire.
    func prepare() {
        guard panel == nil else { return }
        let panel = makePanel()
        self.panel = panel
        position(panel)
        panel.contentView?.layoutSubtreeIfNeeded()
    }

    func show() {
        hideWork?.cancel()
        let panel = self.panel ?? makePanel()
        self.panel = panel
        position(panel)
        panel.alphaValue = 1
        if !panel.isVisible { panel.orderFrontRegardless() }
        withAnimation(Theme.reduceMotion ? .easeOut(duration: 0.1) : .spring(duration: 0.22, bounce: 0)) {
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
        let height = top + HUDView.row + 32  // place pour l'ombre
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

/// Le bandeau sort de l'encoche comme une Dynamic Island : il part de la taille exacte de l'encoche
/// (noir sur noir, donc invisible), s'élargit et descend d'un ressort vif, puis le contenu apparaît.
struct HUDView: View {
    @EnvironmentObject var app: AppController
    @ObservedObject var model: HUDModel
    let notchHeight: CGFloat
    let notchWidth: CGFloat

    /// Hauteur de la ligne sous l'encoche, et débord de chaque côté de l'encoche.
    static let row: CGFloat = 38
    static let side: CGFloat = 76
    private let ear: CGFloat = 6

    private var collapsed: CGSize { CGSize(width: notchWidth > 0 ? notchWidth : 180, height: notchHeight) }
    private var expanded: CGSize {
        CGSize(width: max(collapsed.width + 2 * Self.side, 320), height: notchHeight + Self.row)
    }

    var body: some View {
        let size = model.visible ? expanded : collapsed
        VStack(spacing: 0) {
            ZStack(alignment: .bottom) {
                NotchShape(ear: ear, radius: model.visible ? 19 : 10)
                    .fill(Color.black)
                    .shadow(color: .black.opacity(model.visible ? 0.28 : 0), radius: 14, y: 6)
                row
                    .frame(width: expanded.width - 2 * ear - 36, height: Self.row)
                    .opacity(model.visible ? 1 : 0)
                    .blur(radius: model.visible ? 0 : 6)
                    .scaleEffect(model.visible ? 1 : 0.86, anchor: .top)
                    .animation(Theme.reduceMotion ? .easeOut(duration: 0.1)
                               : .spring(response: 0.3, dampingFraction: 0.85).delay(model.visible ? 0.06 : 0),
                               value: model.visible)
            }
            .frame(width: size.width + 2 * ear, height: max(size.height, 1))
            .animation(Theme.reduceMotion ? .easeOut(duration: 0.12)
                       : .spring(response: 0.34, dampingFraction: model.visible ? 0.74 : 0.9), value: model.visible)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
    }

    private var row: some View {
        HStack(spacing: 10) {
            content
        }
        .id(phaseKey)
        .transition(Theme.reduceMotion ? .opacity
                    : .opacity.combined(with: .modifier(active: BlurModifier(radius: 4), identity: BlurModifier(radius: 0))))
        .animation(Theme.reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.26, dampingFraction: 0.9), value: phaseKey)
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(Color.white)
        .lineLimit(1)
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
            RibbonMark(height: 20, level: app.level, animated: true)
            Text(handsFree ? "J'écoute · mains libres" : "J'écoute")
            Spacer(minLength: 8)
            Elapsed(since: app.recordingStart)
        case .transcribing, .polishing:
            ThinkingDots()
            Text("Mise au propre")
            Spacer(minLength: 0)
        case .translating(let language):
            Image(systemName: "globe").font(.system(size: 14, weight: .semibold))
            Text("Traduction en \(language.lowercased())")
            Spacer(minLength: 0)
        case .done(let label):
            Image(systemName: "checkmark.circle.fill").font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color(red: 0.42, green: 0.84, blue: 0.57))
            Text(label)
            Spacer(minLength: 0)
        case .failed(let message):
            Image(systemName: "exclamationmark.circle.fill").font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.wave)
            Text(message).foregroundStyle(Color.white.opacity(0.85)).truncationMode(.tail)
            Spacer(minLength: 0)
        case .idle:
            EmptyView()
        }
    }
}

/// Durée de la dictée en cours, à droite du bandeau.
private struct Elapsed: View {
    let since: Date?

    var body: some View {
        TimelineView(.periodic(from: since ?? .now, by: 1)) { ctx in
            let s = max(0, Int(ctx.date.timeIntervalSince(since ?? ctx.date)))
            Text(String(format: "%d:%02d", s / 60, s % 60))
                .font(.system(size: 13, weight: .medium).monospacedDigit())
                .foregroundStyle(Color.white.opacity(0.55))
        }
    }
}

/// Trois points qui respirent pendant la mise au propre.
private struct ThinkingDots: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: Theme.reduceMotion)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { i in
                    let wave = Theme.reduceMotion ? 0.6 : 0.35 + 0.65 * max(0, sin((t * 2 * .pi / 0.9) - Double(i) * 0.9))
                    Circle().fill(Color.white.opacity(wave)).frame(width: 5, height: 5)
                        .offset(y: Theme.reduceMotion ? 0 : -2 * wave)
                }
            }
            .frame(width: 22)
        }
    }
}

/// Silhouette d'encoche de MacBook : haut droit, bas arrondi, et raccords incurvés (« oreilles »)
/// qui la fondent dans le bord de l'écran.
struct NotchShape: Shape {
    static let defaultEar: CGFloat = 4
    var ear: CGFloat = NotchShape.defaultEar
    var radius: CGFloat = 16

    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let r = min(radius, (w - 2 * ear) / 2, h)
        var p = Path()
        p.move(to: CGPoint(x: 0, y: 0))
        p.addLine(to: CGPoint(x: w, y: 0))
        p.addQuadCurve(to: CGPoint(x: w - ear, y: ear), control: CGPoint(x: w - ear, y: 0))
        p.addLine(to: CGPoint(x: w - ear, y: h - r))
        p.addQuadCurve(to: CGPoint(x: w - ear - r, y: h), control: CGPoint(x: w - ear, y: h))
        p.addLine(to: CGPoint(x: ear + r, y: h))
        p.addQuadCurve(to: CGPoint(x: ear, y: h - r), control: CGPoint(x: ear, y: h))
        p.addLine(to: CGPoint(x: ear, y: ear))
        p.addQuadCurve(to: CGPoint(x: 0, y: 0), control: CGPoint(x: ear, y: 0))
        p.closeSubpath()
        return p
    }
}
