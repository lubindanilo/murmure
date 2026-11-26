import AppKit
import AVFoundation
import SwiftUI

/// Fenêtre d'accueil du premier lancement : une étape à la fois, autorisations détectées
/// automatiquement, modèles téléchargés en arrière-plan, essai guidé, puis plus jamais visible.
@MainActor
final class OnboardingWindow: NSObject, NSWindowDelegate {
    static let shared = OnboardingWindow()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let root = OnboardingView { [weak self] in self?.finish() }
                .environmentObject(AppController.shared)
                .environmentObject(Settings.shared)
            let controller = NSHostingController(rootView: root)
            // Taille fixe : la vue passe sous la barre de titre transparente, sans marge ajoutée en bas.
            controller.sizingOptions = []
            let window = NSWindow(contentViewController: controller)
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.setContentSize(NSSize(width: OnboardingView.size.width, height: OnboardingView.size.height))
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func finish() {
        Settings.shared.hasCompletedOnboarding = true
        // Une app de dictée doit être là au démarrage du Mac ; désactivable dans les réglages.
        if !LaunchAtLogin.isEnabled { LaunchAtLogin.set(true) }
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

enum OnboardingStep: Int, CaseIterable {
    case welcome, microphone, accessibility, key, tryIt, done
}

struct OnboardingView: View {
    static let size = CGSize(width: 640, height: 580)
    static let stageHeight: CGFloat = 300

    let onFinish: () -> Void
    @EnvironmentObject var app: AppController
    @EnvironmentObject var settings: Settings
    @ObservedObject private var setup = Setup.shared
    /// `-demoStep N` en argument ouvre directement l'étape N (captures d'écran en CI).
    @State private var step: OnboardingStep = OnboardingStep(rawValue: UserDefaults.standard.integer(forKey: "demoStep")) ?? .welcome
    private let isDemo = UserDefaults.standard.object(forKey: "demoStep") != nil
    @State private var micGranted = AudioRecorder.permission == .authorized
    @State private var axGranted = HotkeyMonitor.isTrusted
    @State private var keyFlash = false
    @State private var keyMonitor: Any?
    @State private var tryText = ""
    private let poll = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    private var asrReady: Bool {
        guard let asr = setup.items.first(where: { $0.id == "asr" }) else { return false }
        return asr.progress == nil && asr.error == nil
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Theme.stage
                illustration
                    .id(step)
                    .transition(Theme.stepTransition)
            }
            .frame(height: Self.stageHeight)
            .clipped()

            ZStack(alignment: .top) {
            VStack(spacing: 10) {
                Text(title)
                    .font(.system(size: 24, weight: .semibold))
                    .tracking(-0.3)
                Text(message)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                extra
                    .padding(.top, 6)
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: 460)
            .id(step)
            .transition(Theme.stepTransition)
            }
            .padding(.top, 32)

            Spacer(minLength: 0)
            footer
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(Color(nsColor: .windowBackgroundColor))
        .ignoresSafeArea()
        .animation(Theme.stepAnimation, value: step)
        .tint(Theme.voice)
        .onAppear {
            Setup.shared.start()
            installKeyMonitor()
        }
        .onDisappear { if let keyMonitor { NSEvent.removeMonitor(keyMonitor) } }
        .onReceive(poll) { _ in
            micGranted = AudioRecorder.permission == .authorized
            let trusted = HotkeyMonitor.isTrusted
            if trusted && !axGranted { app.restartHotkey() }
            axGranted = trusted
            if isDemo { return }
            if step == .microphone && micGranted { advance() }
            if step == .accessibility && axGranted { advance() }
        }
    }

    // MARK: Navigation

    private func advance() {
        guard let next = OnboardingStep(rawValue: step.rawValue + 1) else {
            onFinish()
            return
        }
        var target = next
        // Autorisations déjà accordées (réinstallation) : on passe directement.
        if target == .microphone && micGranted { target = .accessibility }
        if target == .accessibility && axGranted { target = .key }
        step = target
    }

    private func back() {
        guard var target = OnboardingStep(rawValue: step.rawValue - 1) else { return }
        if target == .accessibility && axGranted { target = .microphone }
        if target == .microphone && micGranted { target = .welcome }
        step = target
    }

    private var canGoBack: Bool { step == .key || step == .tryIt || step == .done }

    /// Sur l'étape « touche », appuyer sur une touche de modification la choisit.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            guard step == .key else { return event }
            if let key = TriggerKey.allCases.first(where: { $0.keyCode == event.keyCode }),
               event.modifierFlags.contains(key.flag) {
                settings.triggerKey = key
                keyFlash = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { keyFlash = false }
            }
            return event
        }
    }

    // MARK: Contenu

    private var title: String {
        switch step {
        case .welcome: return "Parlez. Murmure écrit."
        case .microphone: return "Autorisez le micro"
        case .accessibility: return "Autorisez l'accessibilité"
        case .key: return "Choisissez votre touche"
        case .tryIt: return asrReady ? "Essayez maintenant" : "Préparation de la voix"
        case .done: return "C'est prêt"
        }
    }

    private var message: String {
        switch step {
        case .welcome:
            return "Maintenez une touche, dictez, relâchez. Le texte apparaît là où se trouve votre curseur, dans toutes vos apps. Tout se passe sur ce Mac."
        case .microphone:
            return "Murmure n'écoute que pendant que vous maintenez la touche. Votre voix ne quitte jamais ce Mac."
        case .accessibility:
            return "macOS demande cette autorisation pour détecter votre touche et coller le texte au bon endroit."
        case .key:
            return "Appuyez sur la touche à utiliser. Une touche de modification à droite du clavier fonctionne le mieux."
        case .tryIt:
            return asrReady
                ? "Maintenez \(settings.triggerKey.label), dites une phrase, puis relâchez."
                : "Murmure télécharge son modèle de transcription, une seule fois. Ensuite, tout fonctionne hors ligne."
        case .done:
            return "Murmure vit dans la barre des menus. Maintenez \(settings.triggerKey.label) partout où vous écrivez. Votre essai de 7 jours commence maintenant."
        }
    }

    @ViewBuilder
    private var extra: some View {
        switch step {
        case .microphone:
            if AudioRecorder.permission == .denied {
                Caption("Le micro a été refusé. Activez Murmure dans Réglages Système, Confidentialité et sécurité, Micro.")
            }
        case .accessibility:
            Caption("Activez Murmure dans la liste. Cette fenêtre continue toute seule.")
        case .key:
            Picker("Touche", selection: $settings.triggerKey) {
                ForEach(TriggerKey.allCases) { Text($0.label).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
        case .tryIt:
            if asrReady { tryStatus } else { DownloadList() }
        case .done:
            Caption("Un appui bref lance la dictée mains libres. Échap annule.")
        case .welcome:
            EmptyView()
        }
    }

    @ViewBuilder
    private var tryStatus: some View {
        switch app.phase {
        case .recording: Caption("J'écoute… relâchez quand vous avez fini.", accent: true)
        case .transcribing, .polishing, .translating: Caption("Transcription…")
        case .failed(let message): Caption(message, accent: true)
        default:
            Caption(tryText.isEmpty ? "Le texte apparaîtra dans la note ci-dessus." : "Parfait. C'est aussi simple que ça, dans toutes vos apps.")
        }
    }

    @ViewBuilder
    private var illustration: some View {
        switch step {
        case .welcome: WelcomeArt()
        case .microphone: MicrophoneArt(granted: micGranted)
        case .accessibility: AccessibilityArt(granted: axGranted)
        case .key: KeyboardArt(selected: settings.triggerKey, pressed: keyFlash)
        case .tryIt: NoteArt(text: $tryText, ready: asrReady)
        case .done: MenuBarArt(key: settings.triggerKey)
        }
    }

    // MARK: Pied de fenêtre

    private var footer: some View {
        HStack(spacing: 12) {
            progressDots
            Spacer()
            if canGoBack {
                Button("Retour", action: back)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
            }
            primaryButton
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 28)
        .padding(.top, 16)
    }

    @ViewBuilder
    private var primaryButton: some View {
        switch step {
        case .welcome:
            PrimaryButton("Commencer", action: advance)
        case .microphone:
            if AudioRecorder.permission == .denied {
                PrimaryButton("Ouvrir les Réglages") { HotkeyMonitor.openMicrophoneSettings() }
            } else {
                PrimaryButton("Autoriser le micro") {
                    Task { micGranted = await AudioRecorder.requestPermission() }
                }
            }
        case .accessibility:
            PrimaryButton("Ouvrir les Réglages") {
                HotkeyMonitor.promptForAccessibility()
                HotkeyMonitor.openAccessibilitySettings()
            }
        case .key:
            PrimaryButton("Continuer", action: advance)
        case .tryIt:
            PrimaryButton(tryText.isEmpty ? "Passer" : "Continuer", prominent: !tryText.isEmpty, action: advance)
        case .done:
            PrimaryButton("Terminer", action: onFinish)
        }
    }

    private var progressDots: some View {
        HStack(spacing: 6) {
            ForEach(OnboardingStep.allCases, id: \.self) { s in
                Capsule()
                    .fill(s == step ? Color.primary.opacity(0.75) : Color.primary.opacity(0.15))
                    .frame(width: s == step ? 16 : 6, height: 6)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Étape \(step.rawValue + 1) sur \(OnboardingStep.allCases.count)")
    }
}

// MARK: - Illustrations

/// Icône de l'app et panneau de dictée qui suit une voix simulée.
private struct WelcomeArt: View {
    var body: some View {
        VStack(spacing: 28) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 128, height: 128)
            HUDCapsule {
                SimulatedWaveform()
                Text("0:03")
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.hudSecondary)
            }
        }
        .padding(.top, 20)
    }
}

/// Réplique de la demande d'autorisation de macOS.
private struct MicrophoneArt: View {
    let granted: Bool

    var body: some View {
        VStack(spacing: 14) {
            ZStack(alignment: .bottomTrailing) {
                Image(nsImage: NSApp.applicationIconImage).resizable().interpolation(.high).frame(width: 56, height: 56)
                Image(systemName: "mic.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.gray))
                    .overlay(Circle().strokeBorder(Color(nsColor: .controlBackgroundColor), lineWidth: 2))
                    .offset(x: 4, y: 4)
            }
            Text("« Murmure » souhaite accéder\nau micro.")
                .font(.system(size: 13, weight: .semibold))
                .multilineTextAlignment(.center)
            HStack(spacing: 8) {
                FakeButton(title: "Refuser", prominent: false)
                FakeButton(title: granted ? "Autorisé" : "Autoriser", prominent: true)
            }
        }
        .padding(20)
        .frame(width: 272)
        .card(radius: 18)
        .padding(.top, 20)
    }
}

/// Ligne « Murmure » de Réglages Système > Accessibilité, interrupteur compris.
private struct AccessibilityArt: View {
    let granted: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "accessibility")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.blue))
                Text("Accessibilité").font(.system(size: 13, weight: .semibold))
            }
            .padding(14)
            Divider()
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage).resizable().interpolation(.high).frame(width: 26, height: 26)
                Text("Murmure").font(.system(size: 13))
                Spacer()
                FakeSwitch(on: granted)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Theme.voice.opacity(granted ? 0 : 0.06))
        }
        .frame(width: 320)
        .card(radius: 14)
        .overlay(alignment: .bottomTrailing) {
            if !granted {
                Image(systemName: "cursorarrow")
                    .font(.system(size: 22))
                    .foregroundStyle(.primary)
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                    .offset(x: -14, y: 10)
            }
        }
        .padding(.top, 20)
    }
}

/// Rangée basse d'un clavier de Mac, touche choisie en couleur.
private struct KeyboardArt: View {
    let selected: TriggerKey
    let pressed: Bool

    private struct Key: Identifiable {
        let id: String
        let glyph: String
        let name: String
        var width: CGFloat = 52
        var trigger: TriggerKey?
    }

    private let keys: [Key] = [
        Key(id: "fn", glyph: "globe", name: "fn", trigger: .fn),
        Key(id: "ctrl", glyph: "⌃", name: "control"),
        Key(id: "lopt", glyph: "⌥", name: "option", trigger: .leftOption),
        Key(id: "lcmd", glyph: "⌘", name: "command", width: 64),
        Key(id: "space", glyph: "", name: "", width: 196),
        Key(id: "rcmd", glyph: "⌘", name: "command", width: 64, trigger: .rightCommand),
        Key(id: "ropt", glyph: "⌥", name: "option", trigger: .rightOption),
    ]

    var body: some View {
        let onRow = keys.contains { $0.trigger == selected }
        VStack(spacing: 18) {
            if onRow {
                HStack(spacing: 6) {
                    ForEach(keys) { key in
                        KeyCapView(glyph: key.glyph, name: key.name, width: key.width,
                                   highlighted: key.trigger == selected, pressed: pressed && key.trigger == selected)
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.primary.opacity(0.07)))
            } else {
                KeyCapView(glyph: String(selected.label.prefix(1)), name: selected.label, width: 120,
                           highlighted: true, pressed: pressed)
            }
            Text(selected.label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.voice)
        }
        .animation(Theme.quick, value: selected)
        .padding(.top, 20)
    }
}

private struct KeyCapView: View {
    let glyph: String
    let name: String
    let width: CGFloat
    let highlighted: Bool
    let pressed: Bool

    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            Group {
                if glyph == "globe" {
                    Image(systemName: "globe").font(.system(size: 11, weight: .medium))
                } else {
                    Text(glyph).font(.system(size: 13, weight: .medium))
                }
            }
            .frame(maxWidth: .infinity, alignment: glyph == "globe" ? .leading : .trailing)
            Spacer(minLength: 0)
            Text(name)
                .font(.system(size: 9, weight: .medium))
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .foregroundStyle(highlighted ? Color.white : Color.primary.opacity(0.75))
        .padding(7)
        .frame(width: width, height: 52)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(highlighted ? Theme.voice : Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(pressed ? 0.05 : 0.18), radius: 0, y: pressed ? 0 : 1.5)
                .shadow(color: .black.opacity(0.06), radius: 3, y: 1)
        )
        .offset(y: pressed ? 1.5 : 0)
        .scaleEffect(pressed && !Theme.reduceMotion ? 0.96 : 1)
        .animation(.easeOut(duration: 0.15), value: pressed)
        .animation(Theme.quick, value: highlighted)
        .accessibilityHidden(true)
    }
}

/// Une note où la dictée d'essai s'écrit vraiment ; avant, l'attente du téléchargement.
private struct NoteArt: View {
    @Binding var text: String
    let ready: Bool
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Circle().fill(Color(red: 1, green: 0.37, blue: 0.34)).frame(width: 11, height: 11)
                Circle().fill(Color(red: 1, green: 0.74, blue: 0.18)).frame(width: 11, height: 11)
                Circle().fill(Color(red: 0.16, green: 0.78, blue: 0.25)).frame(width: 11, height: 11)
                Spacer()
            }
            .overlay(Text("Note d'essai").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary))
            .padding(.horizontal, 14)
            .frame(height: 34)
            Divider()
            ZStack(alignment: .topLeading) {
                if ready {
                    TextEditor(text: $text)
                        .font(.system(size: 15))
                        .scrollContentBackground(.hidden)
                        .scrollIndicators(.never)
                        .focused($focused)
                        .onAppear { focused = true }
                    if text.isEmpty {
                        Text("Votre dictée s'écrira ici.")
                            .font(.system(size: 15))
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                } else {
                    VStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Téléchargement du modèle…").font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .padding(14)
        }
        .frame(width: 460, height: 196)
        .card(radius: 12)
        .padding(.top, 24)
    }
}

/// La barre des menus, l'icône de Murmure et son menu ouvert.
private struct MenuBarArt: View {
    let key: TriggerKey

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            HStack(spacing: 16) {
                Image(systemName: "waveform")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 30, height: 22)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.primary.opacity(0.12)))
                Image(systemName: "wifi").font(.system(size: 13, weight: .medium))
                Image(systemName: "battery.75percent").font(.system(size: 15))
                Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .medium))
                Text("jeu. 9:41").font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(Color.primary.opacity(0.85))
            .padding(.horizontal, 16)
            .frame(width: 520, height: 30, alignment: .trailing)
            .card(radius: 10)

            VStack(alignment: .leading, spacing: 2) {
                MenuRow(title: "Dicter", shortcut: key.label, highlighted: true)
                Divider().padding(.vertical, 3).padding(.horizontal, 10)
                MenuRow(title: "Réglages…", shortcut: "⌘,")
                MenuRow(title: "Quitter Murmure", shortcut: "⌘Q")
            }
            .padding(5)
            .frame(width: 236)
            .card(radius: 10)
            .padding(.trailing, 12)
        }
        .padding(.top, 20)
    }
}

private struct MenuRow: View {
    let title: String
    let shortcut: String
    var highlighted = false

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(shortcut).foregroundStyle(highlighted ? Color.white.opacity(0.8) : Color.secondary)
        }
        .font(.system(size: 13))
        .foregroundStyle(highlighted ? Color.white : Color.primary)
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(highlighted ? Color.accentColor : Color.clear))
    }
}

// MARK: - Composants

private struct DownloadList: View {
    @ObservedObject private var setup = Setup.shared

    var body: some View {
        VStack(spacing: 10) {
            ForEach(setup.items) { item in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(item.title).font(.system(size: 13, weight: .medium))
                        Spacer()
                        if let p = item.progress {
                            Text(p.formatted(.percent.precision(.fractionLength(0))))
                                .font(.system(size: 13).monospacedDigit())
                                .foregroundStyle(.secondary)
                        } else if item.error == nil {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        }
                    }
                    if let p = item.progress { ProgressView(value: p).progressViewStyle(.linear) }
                    if let error = item.error {
                        HStack {
                            Text(error).font(.caption).foregroundStyle(Theme.voice).lineLimit(2)
                            Spacer()
                            Button("Réessayer") { setup.install() }.controlSize(.small)
                        }
                    }
                }
            }
        }
        .frame(width: 360)
    }
}

struct PrimaryButton: View {
    let title: String
    var prominent = true
    let action: () -> Void

    init(_ title: String, prominent: Bool = true, action: @escaping () -> Void) {
        self.title = title
        self.prominent = prominent
        self.action = action
    }

    var body: some View {
        if prominent {
            label.buttonStyle(.borderedProminent).tint(Theme.voice).keyboardShortcut(.defaultAction)
        } else {
            label.buttonStyle(.bordered)
        }
    }

    private var label: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .frame(minWidth: 120)
        }
        .controlSize(.large)
    }
}

private struct Caption: View {
    let text: String
    var accent = false
    init(_ text: String, accent: Bool = false) { self.text = text; self.accent = accent }

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(accent ? Theme.voice : Color.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct FakeButton: View {
    let title: String
    let prominent: Bool

    var body: some View {
        Text(title)
            .font(.system(size: 13, weight: prominent ? .semibold : .regular))
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .frame(maxWidth: .infinity)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(prominent ? Color.accentColor : Color.primary.opacity(0.08)))
            .accessibilityHidden(true)
    }
}

private struct FakeSwitch: View {
    let on: Bool

    var body: some View {
        Capsule()
            .fill(on ? Color.accentColor : Color.primary.opacity(0.14))
            .frame(width: 38, height: 22)
            .overlay(alignment: on ? .trailing : .leading) {
                Circle().fill(Color.white).shadow(color: .black.opacity(0.2), radius: 1, y: 0.5).padding(2)
            }
            .animation(Theme.quick, value: on)
            .accessibilityHidden(true)
    }
}

/// Panneau sombre en forme de gélule, le même que pendant la dictée.
struct HUDCapsule<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 10) { content() }
            .padding(.horizontal, 16)
            .frame(height: 40)
            .background(Capsule(style: .continuous).fill(Theme.hudBackground))
            .overlay(Capsule(style: .continuous).strokeBorder(Theme.hudStroke, lineWidth: 1))
            .shadow(color: .black.opacity(0.22), radius: 12, y: 6)
            .environment(\.colorScheme, .dark)
    }
}

/// Barres animées par une voix simulée (illustrations).
struct SimulatedWaveform: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: Theme.reduceMotion)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let level = Float(0.35 + 0.65 * abs(sin(t * 3.1) * sin(t * 1.7)))
            Waveform(level: Theme.reduceMotion ? 0.5 : level, active: true)
        }
    }
}

extension View {
    /// Surface surélevée : contenu découpé, ombre douce et liseré d'un demi point.
    func card(radius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return self
            .clipShape(shape)
            .background(
                shape
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .shadow(color: .black.opacity(0.10), radius: 16, y: 8)
                    .shadow(color: .black.opacity(0.06), radius: 1, y: 0.5)
            )
            .overlay(shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
    }
}
