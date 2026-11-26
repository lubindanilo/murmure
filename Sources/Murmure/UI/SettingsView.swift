import AVFoundation
import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case general, modes, dictionary, license
    var id: String { rawValue }

    /// Les anciens liens murmure://tab/ai ouvrent Général.
    init?(rawValue: String) {
        switch rawValue {
        case "general", "ai", "models": self = .general
        case "modes": self = .modes
        case "dictionary", "corrections": self = .dictionary
        case "history": self = .general
        case "license": self = .license
        default: return nil
        }
    }

    var title: String {
        switch self {
        case .general: return "Général"
        case .modes: return "Modes"
        case .dictionary: return "Corrections"
        case .license: return "Licence"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape.fill"
        case .modes: return "square.stack.fill"
        case .dictionary: return "text.badge.checkmark"
        case .license: return "key.fill"
        }
    }

    /// Une couleur par section, comme dans Réglages Système.
    var color: Color {
        switch self {
        case .general: return Color(white: 0.55)
        case .modes: return Theme.voice
        case .dictionary: return .blue
        case .license: return .green
        }
    }
}

/// Pastille colorée avec un symbole blanc, à la façon de Réglages Système.
struct SettingsIcon: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 22

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.27, style: .continuous).fill(color.gradient))
            .accessibilityHidden(true)
    }
}

final class SettingsNavigation: ObservableObject {
    /// Pile de navigation : vide = page principale ; sinon la sous-page ouverte.
    @Published var path: [SettingsSection] = []

    func open(_ section: SettingsSection) {
        path = section == .general ? [] : [section]
    }
}

/// Une seule page de réglages ; Modes, Dictionnaire, Historique et Licence s'ouvrent par-dessus.
struct SettingsView: View {
    @EnvironmentObject var nav: SettingsNavigation

    var body: some View {
        NavigationStack(path: $nav.path) {
            GeneralSettings()
                .navigationTitle("Murmure")
                .navigationDestination(for: SettingsSection.self) { section in
                    Group {
                        switch section {
                        case .general: GeneralSettings()
                        case .modes: ModesSettings()
                        case .dictionary: CorrectionsSettings()
                        case .license: LicenseView()
                        }
                    }
                    .subpage(title: section.title, back: "Réglages") { nav.path.removeAll() }
                }
        }
        .tint(Theme.voice)
    }
}

// MARK: - Général

struct GeneralSettings: View {
    @EnvironmentObject var nav: SettingsNavigation
    @EnvironmentObject var settings: Settings
    @EnvironmentObject var app: AppController
    @State private var micStatus = AudioRecorder.permission
    @State private var axTrusted = HotkeyMonitor.isTrusted
    @ObservedObject private var modes = ModeStore.shared
    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var needsSetup: Bool { micStatus != .authorized || !axTrusted }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 48, height: 48)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(needsSetup ? "Encore une étape" : "Prêt à dicter")
                            .font(.system(size: 15, weight: .semibold))
                        Text(needsSetup
                             ? "Autorisez le micro et l'accessibilité."
                             : "Maintenez \(settings.triggerKey.label) et parlez.")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { nav.open(.license) } label: { LicenseBadge() }
                        .buttonStyle(.plain)
                }
                .padding(.vertical, 4)
            }

            SetupSection()

            if needsSetup {
            Section("Autorisations") {
                PermissionRow(title: "Micro", granted: micStatus == .authorized,
                              detail: micStatus == .denied ? "Refusé : à réactiver dans Réglages Système" : "Pour enregistrer votre voix") {
                    if micStatus == .notDetermined {
                        Task {
                            _ = await AudioRecorder.requestPermission()
                            micStatus = AudioRecorder.permission
                        }
                    } else {
                        HotkeyMonitor.openMicrophoneSettings()
                    }
                }
                PermissionRow(title: "Accessibilité", granted: axTrusted,
                              detail: "Pour la touche de dictée et le collage au curseur") {
                    HotkeyMonitor.promptForAccessibility()
                    HotkeyMonitor.openAccessibilitySettings()
                }
            }

            }

            Section {
                Picker("Touche de dictée", selection: $settings.triggerKey) {
                    ForEach(TriggerKey.allCases) { Text($0.label).tag($0) }
                }
                Toggle(isOn: $settings.aiEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Nettoyer le texte")
                        Text("Retire les hésitations et corrige la ponctuation, sur ce Mac.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .onChange(of: settings.aiEnabled) { _, on in if on { Setup.shared.install() } else { PostProcessor.shared.unload() } }
            } footer: {
                Text("Maintenez la touche pour dicter. Un appui bref lance la dictée mains libres, Échap annule.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                NavigationLink(value: SettingsSection.modes) {
                    SettingsRow(section: .modes, value: "\(modes.modes.count)")
                }
                NavigationLink(value: SettingsSection.dictionary) {
                    SettingsRow(section: .dictionary, value: settings.replacements.isEmpty ? "" : "\(settings.replacements.count)")
                }
            }
        }
        .formStyle(.grouped)
        .onReceive(poll) { _ in
            micStatus = AudioRecorder.permission
            let trusted = HotkeyMonitor.isTrusted
            if trusted && !axTrusted { app.restartHotkey() }
            axTrusted = trusted
        }
    }
}

/// Barre du haut des sous-pages : retour à gauche, titre au centre.
/// La fenêtre n'a pas de barre d'outils ; le retour est donc dans le contenu.
struct SubpageBar: View {
    let title: String
    let back: String
    let action: () -> Void

    var body: some View {
        ZStack {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .frame(maxWidth: 260)
            HStack {
                Button(action: action) {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
                        Text(back)
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 26)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.voice)
                .keyboardShortcut("[", modifiers: .command)
                .help("Retour (⌘[)")
                Spacer()
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
    }
}

extension View {
    /// Sous-page : barre de retour en haut, contenu en dessous, sans bouton système.
    func subpage(title: String, back: String, action: @escaping () -> Void) -> some View {
        VStack(spacing: 0) {
            SubpageBar(title: title, back: back, action: action)
            Divider().opacity(0.5)
            self
        }
        .navigationBarBackButtonHidden(true)
    }
}

/// Ligne de la page principale qui ouvre une sous-page.
struct SettingsRow: View {
    let section: SettingsSection
    let value: String

    var body: some View {
        HStack(spacing: 10) {
            SettingsIcon(symbol: section.symbol, color: section.color, size: 24)
            Text(section.title)
            Spacer()
            if !value.isEmpty { Text(value).foregroundStyle(.secondary).monospacedDigit() }
        }
    }
}

/// État de la licence en une pastille : jours d'essai, activée ou à activer.
struct LicenseBadge: View {
    @ObservedObject private var license = LicenseManager.shared

    var body: some View {
        HStack(spacing: 5) {
            Text(label)
            Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).opacity(0.6)
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(Capsule().fill(color.opacity(0.12)))
        .contentShape(Capsule())
        .help("Licence")
    }

    private var label: String {
        switch license.state {
        case .licensed: return "Activé"
        case .trial(let days, _): return days > 1 ? "Essai · \(days) jours" : "Essai · dernier jour"
        case .expired: return "Activer"
        }
    }

    private var color: Color {
        switch license.state {
        case .licensed: return .green
        case .trial: return Theme.voice
        case .expired: return Theme.voice
        }
    }
}

/// Petite touche de clavier, pour rappeler le raccourci.
struct KeyHint: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .shadow(color: .black.opacity(0.16), radius: 0, y: 1)
                    .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
            )
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
    }
}

struct PermissionRow: View {
    let title: String
    let granted: Bool
    let detail: String
    let action: () -> Void

    var body: some View {
        HStack {
            SettingsIcon(symbol: title == "Micro" ? "mic.fill" : "accessibility", color: granted ? .green : .orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(granted ? "Autorisé" : detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !granted {
                Button("Autoriser", action: action)
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

/// Progression de l'installation des modèles au premier lancement.
struct SetupSection: View {
    @ObservedObject private var setup = Setup.shared

    var body: some View {
        if !setup.isComplete {
            Section {
                ForEach(setup.items) { item in
                    HStack(spacing: 10) {
                        Image(systemName: item.progress == nil && item.error == nil ? "checkmark.circle.fill" : "arrow.down.circle")
                            .foregroundStyle(item.progress == nil && item.error == nil ? Color.green : Color.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title)
                            Text(item.error ?? item.detail).font(.caption)
                                .foregroundStyle(item.error == nil ? Color.secondary : Theme.voice)
                                .lineLimit(2)
                        }
                        Spacer()
                        if let p = item.progress {
                            ProgressView(value: p).frame(width: 120)
                            Text(p.formatted(.percent.precision(.fractionLength(0))))
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 36)
                        } else if item.error != nil {
                            Button("Réessayer") { setup.install() }.controlSize(.small)
                        }
                    }
                }
            } header: {
                Text("Installation")
            } footer: {
                Text("Les modèles sont téléchargés une seule fois puis tournent sur ce Mac, hors ligne.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
