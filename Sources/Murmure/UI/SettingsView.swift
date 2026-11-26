import AVFoundation
import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case general, modes, dictionary, history, license
    var id: String { rawValue }

    /// Les anciens liens murmure://tab/ai ouvrent Général.
    init?(rawValue: String) {
        switch rawValue {
        case "general", "ai", "models": self = .general
        case "modes": self = .modes
        case "dictionary": self = .dictionary
        case "history": self = .history
        case "license": self = .license
        default: return nil
        }
    }

    var title: String {
        switch self {
        case .general: return "Général"
        case .modes: return "Modes"
        case .dictionary: return "Dictionnaire"
        case .history: return "Historique"
        case .license: return "Licence"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape.fill"
        case .modes: return "square.stack.fill"
        case .dictionary: return "character.book.closed.fill"
        case .history: return "clock.fill"
        case .license: return "key.fill"
        }
    }

    /// Une couleur par section, comme dans Réglages Système.
    var color: Color {
        switch self {
        case .general: return Color(white: 0.55)
        case .modes: return Theme.voice
        case .dictionary: return .blue
        case .history: return .purple
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
    @Published var section: SettingsSection = .general
}

struct SettingsView: View {
    @EnvironmentObject var nav: SettingsNavigation

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: Binding(
                get: { nav.section }, set: { if let s = $0 { nav.section = s } })) { section in
                Label { Text(section.title) } icon: { SettingsIcon(symbol: section.symbol, color: section.color, size: 20) }
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 190, max: 220)
        } detail: {
            Group {
                switch nav.section {
                case .general: GeneralSettings()
                case .modes: ModesSettings()
                case .dictionary: DictionarySettings()
                case .history: HistoryView()
                case .license: LicenseView()
                }
            }
            .navigationTitle(nav.section.title)
        }
        .tint(Theme.voice)
    }
}

// MARK: - Général

struct GeneralSettings: View {
    @EnvironmentObject var settings: Settings
    @EnvironmentObject var app: AppController
    @State private var micStatus = AudioRecorder.permission
    @State private var axTrusted = HotkeyMonitor.isTrusted
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var needsSetup: Bool { micStatus != .authorized || !axTrusted }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 52, height: 52)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(needsSetup ? "Encore une étape" : "Murmure est prêt")
                            .font(.system(size: 15, weight: .semibold))
                        Text(needsSetup
                             ? "Autorisez le micro et l'accessibilité pour dicter."
                             : "Maintenez \(settings.triggerKey.label) et parlez, dans n'importe quelle app.")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !needsSetup { KeyHint(label: settings.triggerKey.label) }
                }
                .padding(.vertical, 6)
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
                Picker("Comportement", selection: $settings.triggerMode) {
                    ForEach(TriggerMode.allCases) { Text($0.label).tag($0) }
                }
            } header: {
                Text("Raccourci")
            } footer: {
                Text(settings.triggerMode == .hold
                     ? "Un appui bref lance la dictée mains libres. Échap annule."
                     : "Échap annule.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Dictée") {
                Picker("Langue", selection: $settings.language) {
                    ForEach(Languages.all, id: \.code) { Text($0.name).tag($0.code) }
                }
                Toggle(isOn: $settings.aiEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Nettoyer avec l'IA locale")
                        Text("Retire les hésitations, corrige la ponctuation et applique les modes. Sur ce Mac, sans coût.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .onChange(of: settings.aiEnabled) { _, on in if on { Setup.shared.install() } else { PostProcessor.shared.unload() } }
                Toggle("Sons de début et de fin", isOn: $settings.playSounds)
            }

            Section("Démarrage") {
                Toggle("Ouvrir Murmure à l'ouverture de session", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, value in LaunchAtLogin.set(value) }
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
