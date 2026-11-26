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
            controller.sizingOptions = []
            let window = NSWindow(contentViewController: controller)
            window.styleMask = [.titled, .closable]
            window.title = "Murmure"
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
        // Une app de dictée doit être là au démarrage du Mac.
        if !LaunchAtLogin.isEnabled { LaunchAtLogin.set(true) }
        window?.close()
        // Montre où tout se trouve désormais : le panneau sous l'icône de la barre des menus.
        PanelController.shared.show()
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

enum OnboardingStep: Int, CaseIterable {
    case welcome, microphone, accessibility, key, tryIt, done
}

struct OnboardingView: View {
    static let size = CGSize(width: 500, height: 440)

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
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                illustration
                    .id(step)
                    .transition(Theme.stepTransition)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 210)
            .padding(.top, 10)

            ZStack(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 8) {
                    if !title.isEmpty {
                        Text(title)
                            .font(.system(size: 24, weight: .medium))
                            .tracking(-0.5)
                    }
                    if !message.isEmpty {
                        Text(message)
                            .font(.system(size: 13))
                            .foregroundStyle(Palette.muted)
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: 360, alignment: .leading)
                    }
                    extra.padding(.top, title.isEmpty ? 0 : 4)
                }
                .id(step)
                .transition(Theme.stepTransition)
            }
            .padding(.horizontal, 24)
            .padding(.top, 22)

            Spacer(minLength: 0)
            footer
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .foregroundStyle(Palette.ink)
        .background(Palette.card)
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
        case .welcome: return "Bienvenue dans Murmure"
        case .microphone: return "Le micro"
        case .accessibility: return "L'accès au clavier"
        case .key: return "Votre touche"
        case .tryIt: return asrReady ? "Essayez" : ""  // pendant le téléchargement, la barre suffit
        case .done: return "C'est prêt"
        }
    }

    private var message: String {
        switch step {
        case .welcome:
            return "Maintenez une touche, parlez, relâchez."
        case .microphone:
            return "Cliquez sur « Autoriser »."
        case .accessibility:
            return "Activez Murmure dans la liste. On revient ici tout seuls."
        case .key:
            return "Appuyez sur la touche de votre choix."
        case .tryIt:
            return asrReady ? "Maintenez \(settings.triggerKey.label) et parlez." : ""
        case .done:
            return "Murmure vit dans la barre des menus."
        }
    }

    @ViewBuilder
    private var extra: some View {
        switch step {
        case .microphone:
            if AudioRecorder.permission == .denied {
                Caption("Refusé : activez-le dans les Réglages.", accent: true)
            }
        case .tryIt:
            if asrReady { tryStatus } else { ModelDownload() }
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var tryStatus: some View {
        switch app.phase {
        case .recording: Caption("J'écoute… relâchez.", accent: true)
        case .transcribing, .polishing, .translating: Caption("Mise au propre…")
        case .failed(let message): Caption(message, accent: true)
        default:
            if !tryText.isEmpty { Caption("Parfait. Pareil dans toutes vos apps.") }
        }
    }

    @ViewBuilder
    private var illustration: some View {
        switch step {
        case .welcome: RibbonArt()
        case .microphone: MicrophoneAlertDemo(granted: micGranted)
        case .accessibility: SettingsToggleDemo(granted: axGranted).frame(width: 300)
        case .key: KeyboardArt(selected: settings.triggerKey, pressed: keyFlash)
        case .tryIt: NoteArt(text: $tryText, ready: asrReady)
        case .done: ScreenArt()
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
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.muted)
            }
            primaryButton
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 22)
    }

    @ViewBuilder
    private var primaryButton: some View {
        switch step {
        case .welcome:
            PrimaryButton("Commencer", action: advance)
        case .microphone:
            if AudioRecorder.permission == .denied {
                PrimaryButton("Ouvrir les réglages") { PermissionGuide.shared.start(.microphone) }
            } else {
                PrimaryButton("Autoriser le micro") {
                    Task { micGranted = await AudioRecorder.requestPermission() }
                }
            }
        case .accessibility:
            PrimaryButton("Ouvrir les réglages") { PermissionGuide.shared.start(.accessibility) }
        case .key:
            PrimaryButton("Continuer", action: advance)
        case .tryIt:
            PrimaryButton(tryText.isEmpty ? "Passer" : "Continuer", prominent: !tryText.isEmpty, action: advance)
        case .done:
            PrimaryButton("Terminer", action: onFinish)
        }
    }

    private var progressDots: some View {
        HStack(spacing: 5) {
            ForEach(OnboardingStep.allCases, id: \.self) { s in
                Capsule()
                    .fill(s == step ? Theme.voice : Palette.muted.opacity(0.3))
                    .frame(width: s == step ? 14 : 5, height: 5)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Étape \(step.rawValue + 1) sur \(OnboardingStep.allCases.count)")
    }
}

// MARK: - Illustrations

/// Le ruban de Murmure, qui se plie en boucle.
private struct RibbonArt: View {
    var body: some View {
        RibbonMark(height: 150, animated: true)
    }
}

/// Clavier AZERTY dessiné ; la touche choisie s'allume.
private struct KeyboardArt: View {
    let selected: TriggerKey
    let pressed: Bool

    private struct K: Identifiable {
        let id: Int
        let label: String
        var width: CGFloat = 1
        var trigger: TriggerKey?
    }

    private static func row(_ start: Int, _ letters: String) -> [K] {
        letters.enumerated().map { K(id: start + $0.offset, label: String($0.element)) }
    }

    private let rows: [[K]] = [
        row(0, "AZERTYUIOP"),
        row(20, "QSDFGHJKLM"),
        [K(id: 40, label: "⇧", width: 1.3)] + row(41, "WXCVBN.;")
            + [K(id: 60, label: "⇧", width: 1.3, trigger: .rightShift)],
        [K(id: 70, label: "fn", trigger: .fn), K(id: 71, label: "⌃"), K(id: 72, label: "⌥", trigger: .leftOption),
         K(id: 73, label: "⌘", width: 1.2), K(id: 74, label: "", width: 4.6),
         K(id: 75, label: "⌘", width: 1.2, trigger: .rightCommand), K(id: 76, label: "⌥", trigger: .rightOption)],
    ]

    var body: some View {
        VStack(spacing: 10) {
            VStack(spacing: 3) {
                ForEach(rows.indices, id: \.self) { r in
                    HStack(spacing: 3) {
                        ForEach(rows[r]) { key in
                            let on = key.trigger == selected
                            Text(key.label)
                                .font(.system(size: 8, weight: .medium))
                                .foregroundStyle(on ? Theme.onAccent : Palette.muted)
                                .frame(width: 17 * key.width + 3 * (key.width - 1), height: 17)
                                .background(RoundedRectangle(cornerRadius: 3, style: .continuous)
                                    .fill(on ? Theme.voice : Palette.raised)
                                    .shadow(color: .black.opacity(0.10), radius: 0, y: 1))
                                .scaleEffect(on && pressed && !Theme.reduceMotion ? 0.9 : 1)
                                .animation(.easeOut(duration: 0.15), value: pressed)
                        }
                    }
                }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.raised.opacity(0.6))
                .shadow(color: .black.opacity(0.10), radius: 8, y: 4))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 0.5))
            Text(selected.label)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.voice)
        }
        .animation(Theme.quick, value: selected)
    }
}

/// Une note légèrement inclinée où la dictée d'essai s'écrit vraiment.
private struct NoteArt: View {
    @Binding var text: String
    let ready: Bool
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Ma première note").font(.system(size: 11)).foregroundStyle(Palette.muted)
            if ready {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $text)
                        .font(.system(size: 17))
                        .scrollContentBackground(.hidden)
                        .scrollIndicators(.never)
                        .focused($focused)
                        .onAppear { focused = true }
                        .padding(.leading, -5)
                    if text.isEmpty {
                        Text("Votre dictée s'écrira ici.")
                            .font(.system(size: 17))
                            .foregroundStyle(Palette.muted.opacity(0.6))
                            .allowsHitTesting(false)
                    }
                }
            } else {
                Text("Votre dictée s'écrira ici.")
                    .font(.system(size: 17))
                    .foregroundStyle(Palette.muted.opacity(0.6))
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .frame(width: 330, height: 120, alignment: .topLeading)
        .background(Palette.raised)
        .overlay(alignment: .top) { Rectangle().fill(Theme.voice).frame(height: 3) }
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 10, y: 5)
    }
}

/// Un écran miniature : l'icône de Murmure dans la barre des menus.
private struct ScreenArt: View {
    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: [Color(red: 0.13, green: 0.35, blue: 0.85), Color(red: 0.42, green: 0.55, blue: 0.95),
                                    Color(red: 0.98, green: 0.72, blue: 0.48), Color(red: 0.95, green: 0.55, blue: 0.35)],
                           startPoint: .bottomLeading, endPoint: .topTrailing)
            HStack(spacing: 9) {
                Spacer()
                RibbonMark(height: 9, mono: .white)
                    .frame(width: 20, height: 13)
                    .background(RoundedRectangle(cornerRadius: 3).fill(Theme.voice))
                Image(systemName: "wifi").font(.system(size: 8, weight: .semibold))
                Image(systemName: "battery.75percent").font(.system(size: 9))
                Text("Jeu. 26 nov.  09:41").font(.system(size: 7, weight: .medium))
            }
            .foregroundStyle(Color(red: 0.118, green: 0.141, blue: 0.2))
            .padding(.horizontal, 8)
            .frame(height: 16)
            .background(Color.white.opacity(0.7))
            NotchShape(ear: 3, radius: 4)
                .fill(Color.black)
                .frame(width: 62, height: 16)
            ZStack(alignment: .bottomTrailing) {
                Tile(width: 36, height: 34) { RibbonLogo(height: 20) }
                Image(systemName: "cursorarrow").font(.system(size: 15)).foregroundStyle(Color.black)
                    .shadow(color: .white, radius: 1)
                    .offset(x: 12, y: 12)
            }
            .offset(x: 72, y: 26)
        }
        .frame(width: 320, height: 104)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Palette.ink, lineWidth: 3))
    }
}

// MARK: - Composants

/// Tuile blanche en relief (touches, documents).
private struct Tile<Content: View>: View {
    let width: CGFloat
    let height: CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .frame(width: width, height: height)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.raised)
                .shadow(color: .black.opacity(0.14), radius: 0, y: 2)
                .shadow(color: .black.opacity(0.10), radius: 10, y: 5))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 0.5))
    }
}

/// Une seule barre : le modèle de transcription, le seul qui fait attendre la première dictée.
/// Le modèle de nettoyage se télécharge ensuite, en silence.
private struct ModelDownload: View {
    @ObservedObject private var setup = Setup.shared

    private var asr: Setup.Item? { setup.items.first { $0.id == "asr" } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Téléchargement du modèle de transcription")
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                if let p = asr?.progress {
                    Text(p.formatted(.percent.precision(.fractionLength(0))))
                        .font(.system(size: 13).monospacedDigit())
                        .foregroundStyle(Palette.muted)
                }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.muted.opacity(0.18))
                    Capsule().fill(Theme.voice)
                        .frame(width: max(6, geo.size.width * (asr?.progress ?? 0)))
                        .animation(.easeOut(duration: 0.4), value: asr?.progress)
                }
            }
            .frame(height: 6)
            .accessibilityElement()
            .accessibilityLabel("Téléchargement du modèle de transcription")
            .accessibilityValue((asr?.progress ?? 0).formatted(.percent.precision(.fractionLength(0))))
            if let error = asr?.error {
                HStack {
                    Text(error).font(.system(size: 12)).foregroundStyle(Theme.warn).lineLimit(2)
                    Spacer()
                    Button("Réessayer") { setup.install() }.controlSize(.small)
                }
            } else {
                Text("Cela peut prendre jusqu'à 5 minutes.")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
            }
        }
        .frame(width: 400)
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
            Button(title, action: action)
                .buttonStyle(AccentButtonStyle())
                .keyboardShortcut(.defaultAction)
        } else {
            Button(title, action: action)
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.voice)
                .padding(.horizontal, 12)
                .frame(height: 30)
        }
    }
}

private struct Caption: View {
    let text: String
    var accent = false
    init(_ text: String, accent: Bool = false) { self.text = text; self.accent = accent }

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(accent ? Theme.voice : Palette.muted)
            .fixedSize(horizontal: false, vertical: true)
    }
}
