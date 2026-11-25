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
            let window = NSWindow(contentViewController: NSHostingController(rootView: root))
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.setContentSize(NSSize(width: 600, height: 540))
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
    let onFinish: () -> Void
    @EnvironmentObject var app: AppController
    @EnvironmentObject var settings: Settings
    @ObservedObject private var setup = Setup.shared
    /// `-demoStep N` en argument ouvre directement l'étape N (captures d'écran en CI).
    @State private var step: OnboardingStep = OnboardingStep(rawValue: UserDefaults.standard.integer(forKey: "demoStep")) ?? .welcome
    private let isDemo = UserDefaults.standard.object(forKey: "demoStep") != nil
    @State private var micGranted = AudioRecorder.permission == .authorized
    @State private var axGranted = HotkeyMonitor.isTrusted
    private let poll = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            Group {
                switch step {
                case .welcome: welcome
                case .microphone: microphone
                case .accessibility: accessibility
                case .key: KeyStep(next: advance)
                case .tryIt: TryStep(next: advance)
                case .done: done
                }
            }
            .frame(maxWidth: 440)
            .transition(.asymmetric(
                insertion: .opacity.combined(with: .offset(y: Theme.reduceMotion ? 0 : 12)),
                removal: .opacity))
            .id(step)
            Spacer(minLength: 24)
            progressDots
                .padding(.bottom, 28)
        }
        .frame(width: 600, height: 540)
        .background(Color(nsColor: .windowBackgroundColor))
        .animation(Theme.reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.35, dampingFraction: 1), value: step)
        .tint(Theme.voice)
        .onAppear { Setup.shared.start() }
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

    private func advance() {
        guard let next = OnboardingStep(rawValue: step.rawValue + 1) else { return }
        var target = next
        // Autorisations déjà accordées (réinstallation) : on passe directement.
        if target == .microphone && micGranted { target = .accessibility }
        if target == .accessibility && axGranted { target = .key }
        step = target
    }

    private var progressDots: some View {
        HStack(spacing: 8) {
            ForEach(OnboardingStep.allCases, id: \.self) { s in
                Capsule()
                    .fill(s == step ? Theme.voice : Color.primary.opacity(0.15))
                    .frame(width: s == step ? 18 : 6, height: 6)
            }
        }
        .accessibilityHidden(true)
    }

    // MARK: Étapes

    private var welcome: some View {
        StepLayout(symbol: "waveform", title: "Parlez. Murmure écrit.",
                   text: "Maintenez une touche, dictez, relâchez : le texte apparaît là où se trouve votre curseur, dans n'importe quelle app. Tout se passe sur votre Mac, même sans connexion.") {
            PrimaryButton("Commencer", action: advance)
        }
    }

    private var microphone: some View {
        StepLayout(symbol: "mic", title: "Accès au micro",
                   text: "Murmure n'écoute que pendant que vous maintenez la touche de dictée. L'audio ne quitte jamais votre Mac.") {
            if AudioRecorder.permission == .denied {
                PrimaryButton("Ouvrir les Réglages Système") { HotkeyMonitor.openMicrophoneSettings() }
                Hint("Activez Murmure dans Confidentialité et sécurité > Micro.")
            } else {
                PrimaryButton("Autoriser le micro") {
                    Task { micGranted = await AudioRecorder.requestPermission() }
                }
            }
        }
    }

    private var accessibility: some View {
        StepLayout(symbol: "keyboard", title: "Détection de la touche et collage",
                   text: "Pour repérer votre touche de dictée et coller le texte au bon endroit, macOS demande l'autorisation Accessibilité.") {
            PrimaryButton("Ouvrir les Réglages Système") {
                HotkeyMonitor.promptForAccessibility()
                HotkeyMonitor.openAccessibilitySettings()
            }
            Hint("Activez Murmure dans la liste. Cette fenêtre continue toute seule dès que c'est fait.")
        }
    }

    private var done: some View {
        StepLayout(symbol: "checkmark", title: "C'est prêt",
                   text: "Murmure vit dans la barre de menus, en haut à droite. Maintenez \(settings.triggerKey.label) partout où vous écrivez. Vous avez 7 jours d'essai complet, sans carte bancaire.") {
            PrimaryButton("Terminer", action: onFinish)
            Hint("Astuce : un appui bref sur la touche lance la dictée mains libres, Échap annule.")
        }
    }
}

// MARK: - Touche

private struct KeyStep: View {
    let next: () -> Void
    @EnvironmentObject var settings: Settings
    @State private var monitor: Any?
    @State private var flash = false

    var body: some View {
        StepLayout(symbol: nil, title: "Votre touche de dictée",
                   text: "Appuyez sur la touche que vous voulez utiliser. Une touche de modification seule, à droite du clavier, fonctionne le mieux.") {
            KeyCap(label: settings.triggerKey.label, highlighted: flash)
                .padding(.bottom, 6)
            Picker("", selection: $settings.triggerKey) {
                ForEach(TriggerKey.allCases) { Text($0.label).tag($0) }
            }
            .labelsHidden()
            .frame(width: 180)
            PrimaryButton("Continuer", action: next)
        }
        .onAppear {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
                if let key = TriggerKey.allCases.first(where: { $0.keyCode == event.keyCode }),
                   event.modifierFlags.contains(key.flag) {
                    settings.triggerKey = key
                    flash = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { flash = false }
                }
                return event
            }
        }
        .onDisappear { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}

// MARK: - Essai

private struct TryStep: View {
    let next: () -> Void
    @EnvironmentObject var app: AppController
    @EnvironmentObject var settings: Settings
    @ObservedObject private var setup = Setup.shared
    @State private var text = ""
    @FocusState private var focused: Bool

    private var asr: Setup.Item? { setup.items.first { $0.id == "asr" } }
    private var ready: Bool { asr.map { $0.progress == nil && $0.error == nil } ?? false }

    var body: some View {
        StepLayout(symbol: nil, title: ready ? "Essayez maintenant" : "Préparation de la voix",
                   text: ready
                   ? "Maintenez \(settings.triggerKey.label), dites une phrase, puis relâchez."
                   : "Murmure télécharge son modèle de transcription, une seule fois. Il fonctionnera ensuite hors ligne.") {
            if ready {
                TextEditor(text: $text)
                    .font(.system(size: 15))
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .frame(height: 110)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(focused ? Theme.voice.opacity(0.6) : Color.secondary.opacity(0.25)))
                    .focused($focused)
                    .onAppear { focused = true }
                status
                PrimaryButton(text.isEmpty ? "Passer" : "Continuer", prominent: !text.isEmpty, action: next)
            } else {
                downloads
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        switch app.phase {
        case .recording: Hint("J'écoute… relâchez la touche quand vous avez fini.")
        case .transcribing, .polishing, .translating: Hint("Transcription…")
        case .failed(let message): Hint(message, warning: true)
        default:
            Hint(text.isEmpty ? "Le texte apparaîtra ici." : "Parfait. C'est aussi simple que ça, dans toutes vos apps.")
        }
    }

    private var downloads: some View {
        VStack(spacing: 12) {
            ForEach(setup.items) { item in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(item.title).font(.callout.weight(.medium))
                        Spacer()
                        if let p = item.progress {
                            Text(p.formatted(.percent.precision(.fractionLength(0))))
                                .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                        } else if item.error == nil {
                            Image(systemName: "checkmark").foregroundStyle(.secondary)
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
        .frame(width: 340)
    }
}

// MARK: - Composants

private struct StepLayout<Actions: View>: View {
    let symbol: String?
    let title: String
    let text: String
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        VStack(spacing: 18) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(Theme.voice)
                    .frame(width: 72, height: 72)
                    .background(Circle().fill(Theme.voiceSoft))
                    .padding(.bottom, 4)
            }
            Text(title)
                .font(.system(size: 28, weight: .bold))
                .multilineTextAlignment(.center)
            Text(text)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 6)
            VStack(spacing: 12) { actions() }
        }
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
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .frame(minWidth: 200)
                .padding(.vertical, 4)
        }
        .buttonStyle(.borderedProminent)
        .tint(prominent ? Theme.voice : Color.secondary)
        .controlSize(.large)
        .keyboardShortcut(.defaultAction)
    }
}

private struct Hint: View {
    let text: String
    var warning = false
    init(_ text: String, warning: Bool = false) { self.text = text; self.warning = warning }

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(warning ? Theme.voice : Color.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct KeyCap: View {
    let label: String
    let highlighted: Bool

    var body: some View {
        Text(label)
            .font(.system(size: 20, weight: .semibold))
            .padding(.horizontal, 22)
            .frame(height: 56)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(highlighted ? Theme.voiceSoft : Color(nsColor: .controlBackgroundColor))
                    .shadow(color: .black.opacity(0.12), radius: 0, y: 2)
                    .shadow(color: .black.opacity(0.08), radius: 6, y: 3)
            )
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(highlighted ? Theme.voice : Color.secondary.opacity(0.2)))
            .scaleEffect(highlighted && !Theme.reduceMotion ? 0.96 : 1)
            .animation(.easeOut(duration: 0.15), value: highlighted)
    }
}
