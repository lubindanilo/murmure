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

/// Neutres nets et un seul accent, le vermillon de la voix.
enum Palette {
    static let panel = Color.dynamic(light: NSColor(white: 0.972, alpha: 1), dark: NSColor(red: 0.110, green: 0.110, blue: 0.118, alpha: 1))
    static let card = Color.dynamic(light: .white, dark: NSColor(white: 0.165, alpha: 1))
    static let chip = Color.dynamic(light: NSColor(white: 0.918, alpha: 1), dark: NSColor(white: 0.235, alpha: 1))
    static let hero = Color.dynamic(light: NSColor(red: 1, green: 0.949, blue: 0.933, alpha: 1), dark: NSColor(red: 0.235, green: 0.137, blue: 0.118, alpha: 1))
    static let hairline = Color.primary.opacity(0.08)
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
    static let size = NSSize(width: 360, height: 548)

    let router = PanelRouter()
    private var statusItem: NSStatusItem?
    private var panel: KeyPanel?
    private var phaseWatch: AnyCancellable?
    private var outsideClick: Any?
    private var escapeKey: Any?

    var isVisible: Bool { panel?.isVisible == true }

    func install() {
        // Les modes ne sont plus choisis à la main : on oublie un ancien choix devenu invisible.
        ModeStore.shared.pinnedModeID = nil
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = Self.icon(for: .idle)
        item.button?.target = self
        item.button?.action = #selector(toggle(_:))
        statusItem = item
        phaseWatch = AppController.shared.$phase
            .receive(on: RunLoop.main)
            .sink { [weak self] phase in self?.statusItem?.button?.image = Self.icon(for: phase) }
    }

    private static func icon(for phase: AppController.Phase) -> NSImage? {
        let name: String
        switch phase {
        case .recording: name = "waveform.circle.fill"
        case .transcribing, .polishing, .translating: name = "ellipsis.circle"
        default: name = "waveform"
        }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Murmure")
        image?.isTemplate = true
        return image
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
                HomePage().fixedSize(horizontal: false, vertical: true)
            case .mode(let id):
                ModeEditor(modeID: id).frame(height: PanelController.size.height)
            case .corrections:
                CorrectionsSettings()
                    .subpage(title: "Corrections", back: "Murmure") { router.path.removeAll() }
                    .frame(height: 380)
            case .license:
                LicenseView()
                    .subpage(title: "Licence", back: "Murmure") { router.path.removeAll() }
                    .frame(height: 300)
            }
        }
        .frame(width: PanelController.size.width)
        .background(Palette.panel)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
        .tint(Theme.voice)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height in
            PanelController.shared.resize(height: height)
        }
    }
}

/// La page du panneau : état, touche, mode, dernière dictée, corrections, licence.
struct HomePage: View {
    @EnvironmentObject var app: AppController
    @EnvironmentObject var settings: Settings
    @EnvironmentObject var router: PanelRouter
    @ObservedObject private var store = ModeStore.shared
    @ObservedObject private var license = LicenseManager.shared
    @ObservedObject private var setup = Setup.shared
    @ObservedObject private var history = HistoryStore.shared
    @ObservedObject private var updater = Updater.shared
    @State private var micStatus = AudioRecorder.permission
    @State private var axTrusted = HotkeyMonitor.isTrusted
    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var needsPermission: Bool { micStatus != .authorized || !axTrusted }
    private var needsSetup: Bool { needsPermission || !setup.isComplete }
    private var currentModeID: UUID { store.pinnedModeID ?? store.main.id }

    var body: some View {
        VStack(spacing: 0) {
            header
            VStack(alignment: .leading, spacing: 16) {
                if needsSetup { setupCard } else { keyCard }
                writing
                if let last = history.entries.first { lastDictation(last) }
            }
            .padding(.horizontal, 12)
            VStack(spacing: 2) {
                if updater.available != nil {
                    PanelRow(title: "Nouvelle version disponible", value: "Installer", accent: true) { updater.install() }
                }
                PanelRow(title: "Corrections", value: settings.replacements.isEmpty ? "" : "\(settings.replacements.count)") {
                    router.path = [.corrections]
                }
            }
            .padding(.horizontal, 6)
            .padding(.top, 14)
            Divider().padding(.horizontal, 12).padding(.top, 6)
            footer
        }
        .onReceive(poll) { _ in
            micStatus = AudioRecorder.permission
            let trusted = HotkeyMonitor.isTrusted
            if trusted && !axTrusted { app.restartHotkey() }
            axTrusted = trusted
        }
    }

    // MARK: En-tête

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage).resizable().interpolation(.high).frame(width: 24, height: 24)
            Text("Murmure").font(.system(size: 13, weight: .semibold))
            Spacer()
            HStack(spacing: 6) {
                Circle().fill(status.color).frame(width: 6, height: 6)
                Text(status.label).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
    }

    private var status: (label: String, color: Color) {
        switch app.phase {
        case .recording: return ("J'écoute", Theme.voice)
        case .transcribing, .polishing, .translating: return ("Transcription", .orange)
        default: break
        }
        if needsPermission { return ("À configurer", .orange) }
        if !setup.isComplete { return ("Préparation", .orange) }
        if !license.canDictate { return ("Essai terminé", Theme.voice) }
        return ("Prêt", .green)
    }

    // MARK: Touche

    private var keyCard: some View {
        VStack(spacing: 12) {
            BigKeyCap(key: settings.triggerKey, pressed: { if case .recording = app.phase { return true }; return false }())
            VStack(spacing: 3) {
                (Text("Maintenez ") + Text(settings.triggerKey.label).fontWeight(.semibold) + Text(" et parlez"))
                    .font(.system(size: 13))
                Text("Appui bref : mains libres. Échap annule.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Menu {
                Picker("Touche de dictée", selection: $settings.triggerKey) {
                    ForEach(TriggerKey.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Text("Changer de touche")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Theme.voice)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.hero))
    }

    // MARK: Configuration

    private var setupCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            if micStatus != .authorized {
                SetupRow(symbol: "mic.fill", title: "Micro", detail: "Pour entendre votre voix", action: "Autoriser") {
                    if micStatus == .notDetermined {
                        Task { _ = await AudioRecorder.requestPermission(); micStatus = AudioRecorder.permission }
                    } else {
                        HotkeyMonitor.openMicrophoneSettings()
                    }
                }
            }
            if !axTrusted {
                SetupRow(symbol: "accessibility", title: "Accessibilité", detail: "Pour la touche et le collage", action: "Autoriser") {
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
                                .font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                        } else {
                            Button("Réessayer") { setup.install() }.controlSize(.small)
                        }
                    }
                    if let p = item.progress { ProgressView(value: p).progressViewStyle(.linear).controlSize(.small) }
                    if let error = item.error { Text(error).font(.system(size: 11)).foregroundStyle(Theme.voice).lineLimit(2) }
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.hero))
    }

    // MARK: Écriture

    /// Deux interrupteurs remplacent les modes : le ton suit l'app, et l'anglais en option.
    private var writing: some View {
        VStack(spacing: 0) {
            ToggleRow(symbol: "wand.and.stars", title: "Adapter le ton à l'app",
                      detail: "Mail soigné · Messages naturels · Prompts clairs", isOn: $settings.autoTone)
            Divider().padding(.leading, 44)
            ToggleRow(symbol: "globe", title: "Écrire en anglais",
                      detail: "Vous parlez français, Murmure écrit en anglais", isOn: $settings.writeInEnglish)
        }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.card))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 0.5))
    }

    // MARK: Dernière dictée

    private func lastDictation(_ entry: HistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionLabel("Dernière dictée")
                Spacer()
                if history.entries.count > 1 {
                    Menu {
                        ForEach(Array(history.entries.prefix(6).dropFirst())) { e in
                            Button(Self.preview(e.text)) { Self.copy(e.text) }
                        }
                        Divider()
                        Button("Effacer l'historique") { history.clear() }
                    } label: {
                        Text("Précédentes")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                }
            }
            LastDictationCard(text: entry.text)
        }
        .padding(.horizontal, 4)
    }

    static func preview(_ text: String) -> String {
        let line = text.replacingOccurrences(of: "\n", with: " ")
        return line.count > 44 ? String(line.prefix(43)) + "…" : line
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: Pied

    private var footer: some View {
        HStack {
            Button { router.path = [.license] } label: {
                Text(licenseLabel).font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(licenseColor)
            Spacer()
            Button { NSApp.terminate(nil) } label: {
                Image(systemName: "power").font(.system(size: 12, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Quitter Murmure")
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
    }

    private var licenseLabel: String {
        switch license.state {
        case .licensed: return "Murmure est activé"
        case .trial(let days, _): return days > 1 ? "Essai · \(days) jours · Acheter" : "Essai · dernier jour · Acheter"
        case .expired: return "Essai terminé · Activer"
        }
    }

    private var licenseColor: Color {
        if case .licensed = license.state { return .secondary }
        return Theme.voice
    }
}

// MARK: - Composants

struct ToggleRow: View {
    let symbol: String
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isOn ? Theme.voice : Color.secondary)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13))
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .tint(Theme.voice)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(.secondary)
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

/// Grande touche de clavier ; elle s'enfonce pendant la dictée.
struct BigKeyCap: View {
    let key: TriggerKey
    let pressed: Bool

    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            Group {
                if key.glyph == "globe" {
                    Image(systemName: "globe").font(.system(size: 15, weight: .medium))
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(key.glyph).font(.system(size: 17, weight: .medium))
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            Spacer(minLength: 0)
            Text(key.keyName).font(.system(size: 10, weight: .medium)).foregroundStyle(pressed ? Color.white.opacity(0.85) : Color.secondary)
        }
        .foregroundStyle(pressed ? Color.white : Color.primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(width: 84, height: 64)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(pressed ? Theme.voice : Palette.card)
                .shadow(color: .black.opacity(pressed ? 0.04 : 0.16), radius: 0, y: pressed ? 0 : 2)
                .shadow(color: .black.opacity(0.08), radius: 6, y: 3)
        )
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        .offset(y: pressed ? 2 : 0)
        .animation(.easeOut(duration: 0.15), value: pressed)
        .accessibilityLabel("Touche de dictée : \(key.label)")
    }
}

struct ModeChipButton: View {
    let mode: Mode
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: mode.symbol).font(.system(size: 11, weight: .semibold))
                Text(mode.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
            }
            .padding(.leading, 10)
            .padding(.trailing, 12)
            .frame(height: 28)
            .foregroundStyle(selected ? Color.white : Color.primary.opacity(0.8))
            .background(Capsule().fill(selected ? Theme.voice : Palette.chip))
            .contentShape(Capsule())
        }
        .buttonStyle(PressScale())
        .animation(Theme.quick, value: selected)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct LastDictationCard: View {
    let text: String
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.primary.opacity(0.85))
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            Button {
                HomePage.copy(text)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
            } label: {
                ZStack {
                    Image(systemName: "doc.on.doc").opacity(copied ? 0 : 1).scaleEffect(copied ? 0.25 : 1)
                    Image(systemName: "checkmark").foregroundStyle(.green).opacity(copied ? 1 : 0).scaleEffect(copied ? 1 : 0.25)
                }
                .font(.system(size: 12, weight: .medium))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
                .animation(.spring(duration: 0.3, bounce: 0), value: copied)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Copier")
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.card))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 0.5))
    }
}

struct PanelRow: View {
    let title: String
    let value: String
    var accent = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title).font(.system(size: 13))
                Spacer()
                if !value.isEmpty {
                    Text(value).font(.system(size: 12, weight: accent ? .semibold : .regular))
                        .foregroundStyle(accent ? Theme.voice : Color.secondary)
                }
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(hovering ? 0.06 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct SetupRow: View {
    let symbol: String
    let title: String
    let detail: String
    let action: String
    let perform: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            SettingsIcon(symbol: symbol, color: .orange, size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Button(action, action: perform)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
    }
}

/// Appui : légère réduction, jamais en dessous de 0,96.
struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !Theme.reduceMotion ? 0.96 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}
