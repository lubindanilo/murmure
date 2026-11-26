import AppKit
import ServiceManagement
import SwiftUI

@main
struct MurmureApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var app = AppController.shared
    @StateObject private var settings = Settings.shared

    /// L'icône de la barre des menus et son panneau sont gérés par PanelController.
    var body: some Scene {
        SwiftUI.Settings { EmptyView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if CommandLine.arguments.contains(where: { ["--selftest", "--llmtest", "--licensetest"].contains($0) }) {
            Task { @MainActor in exit(await SelfTest.run(CommandLine.arguments)) }
            return
        }
        // Captures d'écran en CI : `-demoDark YES` force l'apparence sombre.
        if UserDefaults.standard.bool(forKey: "demoDark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
        Task { @MainActor in
            AppController.shared.start()
            PanelController.shared.install()
            if let demo = UserDefaults.standard.string(forKey: "demoSettings") {
                PanelController.shared.show(SettingsSection(rawValue: demo) ?? .general)
                if demo == "mode" { PanelController.shared.router.path = [.mode(ModeStore.shared.main.id)] }
            } else if !Settings.shared.hasCompletedOnboarding {
                OnboardingWindow.shared.show()
            } else if !HotkeyMonitor.isTrusted || AudioRecorder.permission != .authorized {
                PanelController.shared.show(.general)
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
                    PanelController.shared.show(SettingsSection(rawValue: name) ?? .general)
                default: break
                }
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Task { @MainActor in PanelController.shared.show(.general) }
        return true
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
