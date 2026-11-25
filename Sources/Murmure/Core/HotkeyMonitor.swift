import AppKit

/// Surveille les touches de dictée (touches de modification seules, comme Spokenly) :
/// la touche principale et celles attribuées à des modes. Échap annule.
final class HotkeyMonitor {
    var onPress: ((TriggerKey) -> Void)?
    var onRelease: ((TriggerKey) -> Void)?
    var onEscape: (() -> Void)?
    /// Une autre touche a été tapée pendant qu'une touche de dictée était enfoncée
    /// (raccourci comme ⌥+lettre) : on n'enregistre pas.
    var onInterrupted: (() -> Void)?

    var keys: Set<TriggerKey> = [.rightOption]

    private var monitors: [Any] = []
    private var down: TriggerKey?

    func start() {
        stop()
        let flags = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] in self?.handleFlags($0) }
        let localFlags = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] in
            self?.handleFlags($0); return $0
        }
        let keyDown = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] in self?.handleKey($0) }
        let localKeyDown = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKey(event); return event
        }
        monitors = [flags, localFlags, keyDown, localKeyDown].compactMap { $0 }
    }

    func stop() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
        down = nil
    }

    private func handleFlags(_ event: NSEvent) {
        guard let key = keys.first(where: { $0.keyCode == event.keyCode }) else { return }
        let pressed = event.modifierFlags.contains(key.flag)
        if pressed, down == nil {
            down = key
            onPress?(key)
        } else if !pressed, down == key {
            down = nil
            onRelease?(key)
        }
    }

    private func handleKey(_ event: NSEvent) {
        if event.keyCode == 53 { onEscape?(); return }
        if down != nil { onInterrupted?() }
    }

    /// Les moniteurs globaux du clavier exigent l'autorisation Accessibilité.
    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func promptForAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    static func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    static func openMicrophoneSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
    }
}
