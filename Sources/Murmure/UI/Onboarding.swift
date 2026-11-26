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
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.card)
                illustration
                    .id(step)
                    .transition(Theme.stepTransition)
            }
            .frame(height: 210)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.horizontal, 14)
            .padding(.top, 14)

            ZStack(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(title)
                        .font(.system(size: 24, weight: .medium))
                        .tracking(-0.5)
                    Text(message)
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.muted)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 360, alignment: .leading)
                    extra.padding(.top, 4)
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
        .background(Palette.window)
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
        case .microphone: return "Autorisez le micro"
        case .accessibility: return "Autorisez l'accessibilité"
        case .key: return "Choisissez votre touche"
        case .tryIt: return asrReady ? "Essayez dans cette note" : "Préparation de la voix"
        case .done: return "C'est prêt"
        }
    }

    private var message: String {
        switch step {
        case .welcome:
            return "Maintenez une touche, parlez, puis relâchez. Vos mots apparaissent au curseur."
        case .microphone:
            return "Murmure écoute pendant l'appui. Votre voix reste sur ce Mac."
        case .accessibility:
            return "macOS demande cet accès pour détecter la touche et coller le texte."
        case .key:
            return "Appuyez sur la touche à maintenir pour dicter."
        case .tryIt:
            return asrReady
                ? "Maintenez \(settings.triggerKey.label), dites une phrase, puis relâchez."
                : "Murmure télécharge son modèle de transcription, une seule fois. Ensuite, tout fonctionne hors ligne."
        case .done:
            return "Retrouvez Murmure en haut de votre écran, dans la barre des menus."
        }
    }

    @ViewBuilder
    private var extra: some View {
        switch step {
        case .microphone:
            if AudioRecorder.permission == .denied {
                Caption("Le micro a été refusé : activez Murmure dans Réglages Système, Confidentialité et sécurité, Micro.", accent: true)
            }
        case .accessibility:
            Caption("Activez Murmure dans la liste. Cette fenêtre continue toute seule.")
        case .tryIt:
            if asrReady { tryStatus } else { DownloadList() }
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var tryStatus: some View {
        switch app.phase {
        case .recording: Caption("J'écoute… relâchez quand vous avez fini.", accent: true)
        case .transcribing, .polishing, .translating: Caption("Mise au propre…")
        case .failed(let message): Caption(message, accent: true)
        default:
            if !tryText.isEmpty { Caption("Parfait. C'est aussi simple que ça, dans toutes vos apps.") }
        }
    }

    @ViewBuilder
    private var illustration: some View {
        switch step {
        case .welcome: RibbonArt()
        case .microphone: MicrophoneArt()
        case .accessibility: AccessibilityArt()
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
                PrimaryButton("Ouvrir les réglages") { HotkeyMonitor.openMicrophoneSettings() }
            } else {
                PrimaryButton("Autoriser le micro") {
                    Task { micGranted = await AudioRecorder.requestPermission() }
                }
            }
        case .accessibility:
            PrimaryButton("Ouvrir les réglages") {
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

/// Le ruban irisé de Murmure, qui oscille doucement.
private struct RibbonArt: View {
    @State private var drift = false

    var body: some View {
        Group {
            if let ribbon = Theme.ribbon {
                Image(nsImage: ribbon)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(height: 172)
                    .rotationEffect(.degrees(drift ? 4 : -4))
                    .scaleEffect(drift ? 1.02 : 0.98)
                    .animation(Theme.reduceMotion ? nil : .easeInOut(duration: 6).repeatForever(autoreverses: true), value: drift)
                    .onAppear { drift = true }
            } else {
                BarsGlyph(height: 60, color: Theme.voice)
            }
        }
    }
}

/// Une touche de micro au centre d'ondes concentriques.
private struct MicrophoneArt: View {
    var body: some View {
        HStack(spacing: 14) {
            WaveBars(count: 9, height: 22)
            ZStack {
                Circle().strokeBorder(Theme.voice.opacity(0.14), lineWidth: 1).frame(width: 140, height: 140)
                Circle().strokeBorder(Theme.voice.opacity(0.22), lineWidth: 1).frame(width: 112, height: 112)
                Tile(width: 72, height: 72) {
                    Image(systemName: "mic").font(.system(size: 30, weight: .regular)).foregroundStyle(Theme.voice)
                }
            }
            WaveBars(count: 9, height: 22)
        }
    }
}

/// La touche relie le texte : ⌘ ··· Aa.
private struct AccessibilityArt: View {
    var body: some View {
        HStack(spacing: 14) {
            Tile(width: 62, height: 58) {
                Text("⌘").font(.system(size: 26, weight: .medium)).foregroundStyle(Theme.voice)
            }
            .rotationEffect(.degrees(-5))
            Line()
                .stroke(Theme.voice.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, dash: [2, 3]))
                .frame(width: 54, height: 1)
            ZStack(alignment: .bottomTrailing) {
                Tile(width: 62, height: 74) {
                    VStack(spacing: 6) {
                        Text("Aa").font(.system(size: 22, weight: .regular, design: .serif)).italic().foregroundStyle(Theme.voice)
                        Capsule().fill(Palette.hairline).frame(width: 30, height: 2)
                        Capsule().fill(Palette.hairline).frame(width: 22, height: 2)
                    }
                }
                Image(systemName: "cursorarrow").font(.system(size: 20)).foregroundStyle(Palette.ink)
                    .offset(x: -6, y: 10)
            }
            .rotationEffect(.degrees(4))
        }
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
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Téléchargement du modèle…").font(.system(size: 13)).foregroundStyle(Palette.muted)
                }
                .padding(.top, 8)
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
        .rotationEffect(.degrees(-1.2))
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
                BarsGlyph(height: 9, color: .white)
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
            ZStack(alignment: .bottomTrailing) {
                Tile(width: 36, height: 34) { BarsGlyph(height: 15, color: Theme.voice) }
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

private struct WaveBars: View {
    let count: Int
    let height: CGFloat

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 24, paused: Theme.reduceMotion)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2.5) {
                ForEach(0..<count, id: \.self) { i in
                    let wave = Theme.reduceMotion ? 0.5 : (sin(t * 4 + Double(i) * 0.8) + 1) / 2
                    Capsule().fill(Theme.voice.opacity(0.8))
                        .frame(width: 2, height: 3 + height * CGFloat(wave) * (i % 2 == 0 ? 1 : 0.6))
                }
            }
            .frame(height: height + 3)
        }
    }
}

private struct Line: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return p
    }
}

private struct DownloadList: View {
    @ObservedObject private var setup = Setup.shared

    var body: some View {
        VStack(spacing: 8) {
            ForEach(setup.items) { item in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(item.title).font(.system(size: 12, weight: .medium))
                        Spacer()
                        if let p = item.progress {
                            Text(p.formatted(.percent.precision(.fractionLength(0))))
                                .font(.system(size: 12).monospacedDigit())
                                .foregroundStyle(Palette.muted)
                        } else if item.error == nil {
                            Image(systemName: "checkmark").foregroundStyle(Palette.ok)
                        }
                    }
                    if let p = item.progress { ProgressView(value: p).progressViewStyle(.linear).controlSize(.small) }
                    if let error = item.error {
                        HStack {
                            Text(error).font(.caption).foregroundStyle(Theme.warn).lineLimit(2)
                            Spacer()
                            Button("Réessayer") { setup.install() }.controlSize(.small)
                        }
                    }
                }
            }
        }
        .frame(width: 320)
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
