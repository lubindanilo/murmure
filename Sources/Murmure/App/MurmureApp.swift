import AppKit
import ServiceManagement
import SwiftUI

@main
struct MurmureApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var app = AppController.shared
    @StateObject private var settings = Settings.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
                .environmentObject(app)
                .environmentObject(settings)
        } label: {
            MenuIcon(phase: app.phase)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if CommandLine.arguments.contains(where: { ["--selftest", "--llmtest", "--licensetest"].contains($0) }) {
            Task { @MainActor in exit(await SelfTest.run(CommandLine.arguments)) }
            return
        }
        Task { @MainActor in
            AppController.shared.start()
            if let demo = UserDefaults.standard.string(forKey: "demoSettings") {
                SettingsWindow.shared.show(SettingsSection(rawValue: demo) ?? .general)
            } else if !Settings.shared.hasCompletedOnboarding {
                OnboardingWindow.shared.show()
            } else if !HotkeyMonitor.isTrusted || AudioRecorder.permission != .authorized {
                SettingsWindow.shared.show(.general)
            }
            Updater.shared.check()
        }
    }

    /// Liens murmure:// :
    ///   start?mode_id=…   démarre une dictée (mode facultatif)
    ///   toggle?mode_id=…  démarre ou termine
    ///   switch?mode_id=…  choisit le mode sans enregistrer
    ///   tab/modes, tab/history… ouvre les réglages
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in
            for url in urls where url.scheme == "murmure" {
                let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first { $0.name == "mode_id" }?.value.flatMap(UUID.init(uuidString:))
                let store = ModeStore.shared
                let app = AppController.shared
                switch url.host {
                case "start": app.startFromLink(mode: store.mode(id) != nil ? id : nil)
                case "toggle": app.toggleFromMenu(mode: store.mode(id) != nil ? id : nil)
                case "switch":
                    if let mode = store.mode(id) { store.pinnedModeID = mode.isMain ? nil : mode.id }
                case "tab":
                    let name = url.pathComponents.dropFirst().first ?? "general"
                    SettingsWindow.shared.show(SettingsSection(rawValue: name) ?? .general)
                default: break
                }
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Task { @MainActor in SettingsWindow.shared.show(.general) }
        return true
    }
}

struct MenuIcon: View {
    let phase: AppController.Phase

    var body: some View {
        switch phase {
        case .recording: Image(systemName: "waveform.circle.fill")
        case .transcribing, .polishing, .translating: Image(systemName: "ellipsis.circle")
        default: Image(systemName: "waveform")
        }
    }
}

struct MenuContent: View {
    @EnvironmentObject var app: AppController
    @EnvironmentObject var settings: Settings
    @ObservedObject private var store = ModeStore.shared
    @ObservedObject private var license = LicenseManager.shared
    @ObservedObject private var setup = Setup.shared

    @ObservedObject private var updater = Updater.shared

    var body: some View {
        Button(recordLabel) { app.toggleFromMenu() }
            .disabled(!setup.isComplete)
        if !setup.isComplete {
            Text("Préparation de la voix…")
        }
        switch license.state {
        case .trial(let days, _) where days <= 3:
            Button("Essai : \(days) jour\(days > 1 ? "s" : "") restant\(days > 1 ? "s" : "")…") { SettingsWindow.shared.show(.license) }
        case .expired:
            Button("Essai terminé : activer Murmure…") { SettingsWindow.shared.show(.license) }
        default:
            EmptyView()
        }

        if store.modes.count > 1 {
            Divider()
            Picker("Mode", selection: Binding(
                get: { store.pinnedModeID ?? store.main.id },
                set: { id in store.pinnedModeID = (id == store.main.id) ? nil : id })) {
                ForEach(store.modes) { Text($0.name).tag($0.id) }
            }
        }

        Divider()
        if updater.available != nil {
            Button("Installer la mise à jour…") { updater.install() }
        }
        Button("Réglages…") { SettingsWindow.shared.show(.general) }
            .keyboardShortcut(",")
        Button("Quitter Murmure") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var recordLabel: String {
        switch app.phase {
        case .recording: return "Terminer la dictée"
        case .transcribing: return "Transcription en cours…"
        case .polishing, .translating: return "Traitement en cours…"
        default: return "Démarrer une dictée"
        }
    }
}

/// Fenêtre de réglages gérée en AppKit : une app de barre de menus n'a pas de fenêtre principale.
@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
    static let shared = SettingsWindow()
    private var window: NSWindow?
    private let navigation = SettingsNavigation()

    func show(_ section: SettingsSection) {
        navigation.section = section
        if window == nil {
            let root = SettingsView()
                .environmentObject(AppController.shared)
                .environmentObject(Settings.shared)
                .environmentObject(navigation)
            let window = NSWindow(contentViewController: NSHostingController(rootView: root))
            window.title = "Murmure"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.toolbarStyle = .unified
            window.setContentSize(NSSize(width: 820, height: 600))
            window.minSize = NSSize(width: 720, height: 480)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // Retour en app de barre de menus, sans icône dans le Dock.
        NSApp.setActivationPolicy(.accessory)
    }
}

enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Murmure : lancement au démarrage impossible : \(error.localizedDescription)")
        }
    }
}
