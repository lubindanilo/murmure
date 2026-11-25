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
        case .general: return "gearshape"
        case .modes: return "square.stack"
        case .dictionary: return "character.book.closed"
        case .history: return "clock.arrow.circlepath"
        case .license: return "key"
        }
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
                Label(section.title, systemImage: section.symbol).tag(section)
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

            Section("Raccourci") {
                Picker("Touche de dictée (mode principal)", selection: $settings.triggerKey) {
                    ForEach(TriggerKey.allCases) { Text($0.label).tag($0) }
                }
                Picker("Comportement", selection: $settings.triggerMode) {
                    ForEach(TriggerMode.allCases) { Text($0.label).tag($0) }
                }
                Text(settings.triggerMode == .hold
                     ? "Un appui bref lance la dictée mains libres. Échap annule."
                     : "Échap annule.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Dictée") {
                Picker("Langue", selection: $settings.language) {
                    ForEach(Languages.all, id: \.code) { Text($0.name).tag($0.code) }
                }
                Toggle(isOn: $settings.aiEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Nettoyer avec l'IA locale")
                        Text("Retire les « euh », corrige la ponctuation et applique les modes. Sur votre Mac, sans coût.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .onChange(of: settings.aiEnabled) { _, on in if on { Setup.shared.install() } else { PostProcessor.shared.unload() } }
                Toggle("Sons de début et de fin", isOn: $settings.playSounds)
            }

            Section {
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

struct PermissionRow: View {
    let title: String
    let granted: Bool
    let detail: String
    let action: () -> Void

    var body: some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(granted ? Color.green : Color.secondary)
                .font(.system(size: 15))
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
                    .controlSize(.small)
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
