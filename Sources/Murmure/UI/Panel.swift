import AppKit
import Combine
import SwiftUI

// MARK: - Couleurs du panneau

extension Color {
    /// Couleur qui suit l'apparence claire ou sombre du système.
    static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}

/// Direction « Sillage » : verre dépoli bleuté, encre marine, un seul accent bleu iris.
enum Palette {
    /// Voile posé sur le flou du panneau.
    static let panel = Color.dynamic(light: NSColor(red: 0.969, green: 0.973, blue: 0.988, alpha: 0.80),
                                     dark: NSColor(red: 0.145, green: 0.169, blue: 0.231, alpha: 0.82))
    /// Fond opaque des fenêtres (onboarding).
    static let window = Color.dynamic(light: NSColor(red: 0.961, green: 0.969, blue: 0.984, alpha: 1),
                                      dark: NSColor(red: 0.137, green: 0.157, blue: 0.216, alpha: 1))
    /// Carte en retrait : dernière dictée, zones d'illustration.
    static let card = Color.dynamic(light: NSColor(red: 0.918, green: 0.933, blue: 0.965, alpha: 1),
                                    dark: NSColor(red: 0.180, green: 0.208, blue: 0.282, alpha: 1))
    /// Pastille sélectionnée d'un sélecteur.
    static let raised = Color.dynamic(light: .white, dark: NSColor(red: 0.255, green: 0.290, blue: 0.384, alpha: 1))
    static let ink = Color.dynamic(light: NSColor(red: 0.118, green: 0.141, blue: 0.200, alpha: 1),
                                   dark: NSColor(red: 0.910, green: 0.922, blue: 0.953, alpha: 1))
    static let muted = Color.dynamic(light: NSColor(red: 0.357, green: 0.392, blue: 0.471, alpha: 1),
                                     dark: NSColor(red: 0.604, green: 0.639, blue: 0.722, alpha: 1))
    static let hairline = Color.dynamic(light: NSColor(red: 0.118, green: 0.141, blue: 0.200, alpha: 0.10),
                                        dark: NSColor(white: 1, alpha: 0.10))
    static let ok = Color.dynamic(light: NSColor(red: 0.180, green: 0.608, blue: 0.369, alpha: 1),
                                  dark: NSColor(red: 0.420, green: 0.835, blue: 0.565, alpha: 1))
    // Anciens noms, gardés pour les vues qui les utilisent encore.
    static let hero = card
    static let chip = card
}

/// Flou d'arrière-plan natif de macOS (verre dépoli).
struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .popover

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) { view.material = material }
}

// MARK: - Navigation

enum PanelRoute: Hashable {
    case mode(UUID)
    case corrections
    case license
}

@MainActor
final class PanelRouter: ObservableObject {
    @Published var path: [PanelRoute] = []

    func open(_ section: SettingsSection) {
        switch section {
        case .general, .modes: path = []
        case .dictionary: path = [.corrections]
        case .license: path = [.license]
        }
    }
}

// MARK: - Fenêtre du panneau

/// Panneau sans bordure qui accepte le clavier (champs de texte des sous-pages).
final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Icône de la barre des menus et panneau qui s'ouvre dessous. Remplace le menu et la fenêtre de réglages.
@MainActor
final class PanelController: NSObject {
    static let shared = PanelController()
    static let size = NSSize(width: 336, height: 480)

    let router = PanelRouter()
    private var statusItem: NSStatusItem?
    private var panel: KeyPanel?
    private var phaseWatch: AnyCancellable?
    private var iconTimer: Timer?
    private var outsideClick: Any?
    private var escapeKey: Any?

    var isVisible: Bool { panel?.isVisible == true }

    func install() {
        // Les modes ne sont plus choisis à la main : on oublie un ancien choix devenu invisible.
        ModeStore.shared.pinnedModeID = nil
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = Self.restingIcon
        item.button?.target = self
        item.button?.action = #selector(toggle(_:))
        statusItem = item
        phaseWatch = AppController.shared.$phase
            .receive(on: RunLoop.main)
            .sink { [weak self] phase in self?.animateIcon(for: phase) }
    }

    /// Le ruban de la barre des menus se plie en boucle pendant la dictée (plus vite quand la voix monte),
    /// plus lentement pendant la mise au propre, et reste immobile le reste du temps.
    private func animateIcon(for phase: AppController.Phase) {
        iconTimer?.invalidate()
        iconTimer = nil
        let busy: Double?
        switch phase {
        case .recording: busy = nil
        case .transcribing, .polishing, .translating: busy = 0.6
        default:
            statusItem?.button?.image = Self.restingIcon
            return
        }
        if Theme.reduceMotion {
            // Sans animation, le ruban replié signale la dictée.
            statusItem?.button?.image = RibbonMotion.templateImage(phase: 0.5) ?? Self.restingIcon
            return
        }
        let clock = RibbonClock()
        let tick = { [weak self] in
            let speed = busy ?? RibbonMotion.speed(level: AppController.shared.level)
            let phase = clock.advance(to: Date.timeIntervalSinceReferenceDate, speed: speed)
            if let image = RibbonMotion.templateImage(phase: phase) { self?.statusItem?.button?.image = image }
        }
        tick()
        let timer = Timer(timeInterval: 1 / RibbonMotion.fps, repeats: true) { _ in tick() }
        RunLoop.main.add(timer, forMode: .common)
        iconTimer = timer
    }

    private static var restingIcon: NSImage? {
        RibbonMotion.templateImage() ?? NSImage(named: NSImage.applicationIconName)
    }

    @objc private func toggle(_ sender: Any?) {
        isVisible ? hide() : show(.general)
    }

    func show(_ section: SettingsSection = .general) {
        router.open(section)
        let panel = self.panel ?? makePanel()
        self.panel = panel
        position(panel)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Theme.reduceMotion ? 0 : 0.15
            panel.animator().alphaValue = 1
        }
        statusItem?.button?.highlight(true)
        // Un clic dans une autre app ou Échap referme le panneau.
        if outsideClick == nil {
            outsideClick = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                Task { @MainActor in self?.hide() }
            }
        }
        if escapeKey == nil {
            escapeKey = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard event.keyCode == 53, event.window === self?.panel else { return event }
                self?.hide()
                return nil
            }
        }
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Theme.reduceMotion ? 0 : 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: {
            Task { @MainActor in panel.orderOut(nil) }
        })
        statusItem?.button?.highlight(false)
        if let outsideClick { NSEvent.removeMonitor(outsideClick) }
        if let escapeKey { NSEvent.removeMonitor(escapeKey) }
        outsideClick = nil
        escapeKey = nil
    }

    private func makePanel() -> KeyPanel {
        let panel = KeyPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        let root = PanelView()
            .environmentObject(AppController.shared)
            .environmentObject(Settings.shared)
            .environmentObject(router)
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: Self.size)
        panel.contentView = host
        return panel
    }

    /// Sous l'icône de la barre des menus, sans dépasser de l'écran.
    /// La hauteur se cale sur le bas de la barre des menus ; l'icône ne sert qu'à l'alignement horizontal,
    /// car sa position n'est pas encore connue juste après le lancement.
    private func position(_ panel: NSPanel) {
        let size = Self.size
        let buttonWindow = statusItem?.button?.window
        let screen = (buttonWindow?.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        var x = screen.maxX - size.width - 8
        if let button = statusItem?.button, let window = buttonWindow {
            let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
            // Les icônes de la barre des menus sont toujours dans la moitié droite ; sinon, position pas encore connue.
            if anchor.width > 0, anchor.midX > screen.midX, anchor.midX < screen.maxX {
                x = anchor.midX - size.width / 2
            }
        }
        x = min(max(x, screen.minX + 8), screen.maxX - size.width - 8)
        let height = panel.frame.height > 0 ? panel.frame.height : size.height
        panel.setFrame(NSRect(x: x, y: screen.maxY - height - 6, width: size.width, height: height), display: true)
    }

    /// La page d'accueil prend la hauteur de son contenu ; le haut du panneau reste sous la barre des menus.
    func resize(height: CGFloat) {
        guard let panel, abs(panel.frame.height - height) > 0.5 else { return }
        let top = panel.frame.maxY
        panel.setFrame(NSRect(x: panel.frame.minX, y: top - height, width: panel.frame.width, height: height), display: true)
    }
}

// MARK: - Contenu

struct PanelView: View {
    @EnvironmentObject var router: PanelRouter

    var body: some View {
        Group {
            switch router.path.last {
            case .none:
                HomePage()
            case .mode(let id):
                ModeEditor(modeID: id).frame(height: PanelController.size.height)
            case .corrections:
                CorrectionsSettings()
            case .license:
                LicenseView()
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: PanelController.size.width)
        .foregroundStyle(Palette.ink)
        .background {
            ZStack {
                VisualEffect(material: .popover)
                Palette.panel
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 0.5))
        .tint(Theme.voice)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height in
            PanelController.shared.resize(height: height)
        }
    }
}

/// Marque : le ruban et le nom.
struct Wordmark: View {
    var size: CGFloat = 15

    var body: some View {
        HStack(spacing: size * 0.4) {
            RibbonLogo(height: size * 1.2)
            Text("Murmure").font(.system(size: size, weight: .semibold)).tracking(-0.3)
        }
    }
}

/// Le panneau : état, touche, langue, ton, dernière dictée, corrections, essai.
struct HomePage: View {
    @EnvironmentObject var app: AppController
    @EnvironmentObject var settings: Settings
    @EnvironmentObject var router: PanelRouter
    @ObservedObject private var license = LicenseManager.shared
    @ObservedObject private var setup = Setup.shared
    @ObservedObject private var history = HistoryStore.shared
    @ObservedObject private var updater = Updater.shared
    @State private var micStatus = AudioRecorder.permission
    @State private var axTrusted = HotkeyMonitor.isTrusted
    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var needsPermission: Bool { micStatus != .authorized || !axTrusted }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Palette.hairline).padding(.horizontal, 16)
            VStack(alignment: .leading, spacing: 0) {
                callouts
                row("Touche de dictée") { KeyPickerChip() }
                row("Écrire en") {
                    Segmented(options: ["Français", "English"],
                              selection: Binding(get: { settings.writeInEnglish ? 1 : 0 },
                                                 set: { settings.writeInEnglish = $0 == 1 }))
                }
                row("Adapter le ton à l'app") {
                    Toggle("", isOn: $settings.autoTone).labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
                .help("Mail : soigné · Slack, Messages : naturel · ChatGPT, Claude, Cursor : prompt clair")
                if let last = history.entries.first {
                    LastDictationCard(text: last.text).padding(.top, 6).padding(.bottom, 4)
                }
                Button { router.path = [.corrections] } label: {
                    HStack {
                        Text("Corrections")
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.muted)
                    }
                    .frame(height: 38)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .font(.system(size: 13))
            .padding(.horizontal, 16)
            .padding(.top, 6)
            Divider().overlay(Palette.hairline).padding(.horizontal, 16)
            footer
        }
        .onReceive(poll) { _ in
            micStatus = AudioRecorder.permission
            let trusted = HotkeyMonitor.isTrusted
            if trusted && !axTrusted { app.restartHotkey() }
            axTrusted = trusted
        }
    }

    private func row<Trailing: View>(_ title: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack {
            Text(title)
            Spacer(minLength: 12)
            trailing()
        }
        .frame(height: 38)
    }

    // MARK: En-tête

    private var header: some View {
        HStack {
            Wordmark()
            Spacer()
            statusView
        }
        .padding(.horizontal, 16)
        .frame(height: 50)
    }

    @ViewBuilder
    private var statusView: some View {
        switch app.phase {
        case .recording:
            HStack(spacing: 6) { RibbonMark(height: 13, level: app.level, animated: true); Text("J'écoute") }
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.voice)
        case .transcribing, .polishing, .translating:
            Text("Mise au propre").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.voice)
        default:
            if needsPermission || !license.canDictate {
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.circle").font(.system(size: 11, weight: .semibold))
                    Text(needsPermission ? "À configurer" : "Essai terminé")
                }
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.warn)
            } else if !setup.isComplete {
                Text("Préparation").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.muted)
            } else {
                HStack(spacing: 6) { Circle().fill(Palette.ok).frame(width: 6, height: 6); Text("Prêt") }
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.ok)
            }
        }
    }

    // MARK: Autorisations, préparation, mise à jour

    @ViewBuilder
    private var callouts: some View {
        if micStatus != .authorized {
            Callout(title: "Autorisez le microphone", detail: "Pour entendre votre voix.",
                    action: micStatus == .notDetermined ? "Autoriser" : "Ouvrir les réglages") {
                if micStatus == .notDetermined {
                    Task { _ = await AudioRecorder.requestPermission(); micStatus = AudioRecorder.permission }
                } else {
                    HotkeyMonitor.openMicrophoneSettings()
                }
            }
        } else if !axTrusted {
            Callout(title: "Autorisez l'accessibilité", detail: "Pour détecter la touche et coller le texte.",
                    action: "Ouvrir les réglages") {
                HotkeyMonitor.promptForAccessibility()
                HotkeyMonitor.openAccessibilitySettings()
            }
        }
        ForEach(setup.items.filter { $0.progress != nil || $0.error != nil }) { item in
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(item.title).font(.system(size: 12, weight: .medium))
                    Spacer()
                    if let p = item.progress {
                        Text(p.formatted(.percent.precision(.fractionLength(0))))
                            .font(.system(size: 12).monospacedDigit()).foregroundStyle(Palette.muted)
                    } else {
                        Button("Réessayer") { setup.install() }.buttonStyle(.plain)
                            .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.voice)
                    }
                }
                if let p = item.progress { ProgressView(value: p).progressViewStyle(.linear).controlSize(.small) }
                if let error = item.error { Text(error).font(.system(size: 11)).foregroundStyle(Theme.warn).lineLimit(2) }
            }
            .padding(.vertical, 8)
        }
        if updater.available != nil {
            Callout(title: "Nouvelle version disponible", detail: "Installation en quelques secondes.",
                    action: "Installer", tint: Theme.voice) { updater.install() }
        }
    }

    // MARK: Pied

    private var footer: some View {
        HStack(spacing: 0) {
            Button { router.path = [.license] } label: {
                switch license.state {
                case .licensed:
                    Text("Murmure est activé").foregroundStyle(Palette.muted)
                case .trial(let days, _):
                    (Text(days > 1 ? "Essai · \(days) jours · " : "Essai · dernier jour · ").foregroundColor(Palette.muted)
                     + Text("Acheter").foregroundColor(Theme.voice).fontWeight(.semibold))
                case .expired:
                    (Text("Essai terminé · ").foregroundColor(Palette.muted)
                     + Text("Activer").foregroundColor(Theme.voice).fontWeight(.semibold))
                }
            }
            .buttonStyle(.plain)
            Spacer()
            Button("Quitter") { NSApp.terminate(nil) }
                .buttonStyle(.plain)
                .foregroundStyle(Palette.muted)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 16)
        .frame(height: 40)
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - Composants

/// Encadré d'alerte : liseré à gauche, titre, détail et action.
struct Callout: View {
    let title: String
    let detail: String
    let action: String
    var tint: Color = Theme.warn
    let perform: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Rectangle().fill(tint).frame(width: 3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(Palette.muted)
                Button(action: perform) {
                    HStack(spacing: 3) {
                        Text(action)
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.voice)
                .padding(.top, 3)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            Spacer(minLength: 0)
        }
        .background(tint.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .padding(.vertical, 6)
    }
}

/// Touche de dictée affichée comme une petite touche ; un clic ouvre la liste.
struct KeyPickerChip: View {
    @EnvironmentObject var settings: Settings

    var body: some View {
        Menu {
            Picker("Touche de dictée", selection: $settings.triggerKey) {
                ForEach(TriggerKey.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 6) {
                Text(settings.triggerKey.label).font(.system(size: 12, weight: .medium))
                Image(systemName: "pencil").font(.system(size: 9, weight: .semibold)).foregroundStyle(Palette.muted)
            }
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Palette.raised))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Changer la touche de dictée")
    }
}

/// Sélecteur à deux options, pastille blanche sur fond en retrait.
struct Segmented: View {
    let options: [String]
    @Binding var selection: Int

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { i in
                Button { selection = i } label: {
                    Text(options[i])
                        .font(.system(size: 12, weight: i == selection ? .medium : .regular))
                        .foregroundStyle(i == selection ? Palette.ink : Palette.muted)
                        .padding(.horizontal, 9)
                        .frame(height: 22)
                        .background {
                            if i == selection {
                                RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Palette.raised)
                                    .shadow(color: .black.opacity(0.12), radius: 1, y: 0.5)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Palette.card))
        .animation(Theme.quick, value: selection)
    }
}

struct LastDictationCard: View {
    let text: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Dernière dictée").font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.muted)
                Spacer()
                Button {
                    HomePage.copy(text)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
                } label: {
                    ZStack {
                        Image(systemName: "doc.on.doc").opacity(copied ? 0 : 1).scaleEffect(copied ? 0.25 : 1)
                        Image(systemName: "checkmark").foregroundStyle(Palette.ok).opacity(copied ? 1 : 0).scaleEffect(copied ? 1 : 0.25)
                    }
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
                    .animation(.spring(duration: 0.3, bounce: 0), value: copied)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Palette.muted)
                .help("Copier")
            }
            Text(text)
                .font(.system(size: 14))
                .lineLimit(3)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.card))
    }
}

extension TriggerKey {
    var glyph: String {
        switch self {
        case .fn: return "globe"
        case .rightOption, .leftOption: return "⌥"
        case .rightCommand: return "⌘"
        case .rightControl: return "⌃"
        case .rightShift: return "⇧"
        }
    }

    var keyName: String {
        switch self {
        case .fn: return "fn"
        case .rightOption, .leftOption: return "option"
        case .rightCommand: return "command"
        case .rightControl: return "control"
        case .rightShift: return "shift"
        }
    }
}

/// Bouton principal plein, accent iris.
struct AccentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.onAccent)
            .padding(.horizontal, 14)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.voice))
            .shadow(color: .black.opacity(0.12), radius: 1, y: 1)
            .scaleEffect(configuration.isPressed && !Theme.reduceMotion ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

/// Barre du haut des sous-pages : chevron de retour, titre centré, action facultative à droite.
struct PanelSubpageBar<Trailing: View>: View {
    let title: String
    let back: () -> Void
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        ZStack {
            Text(title).font(.system(size: 13, weight: .semibold))
            HStack {
                Button(action: back) {
                    Image(systemName: "chevron.left").font(.system(size: 13, weight: .semibold))
                        .frame(width: 28, height: 28).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut("[", modifiers: .command)
                .help("Retour")
                Spacer()
                trailing()
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 46)
        .overlay(alignment: .bottom) { Divider().overlay(Palette.hairline).padding(.horizontal, 16) }
    }
}
