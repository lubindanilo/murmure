import AppKit
import Carbon.HIToolbox

/// Insère le texte dans l'app active : presse-papiers puis ⌘V simulé,
/// et restauration du presse-papiers d'origine.
enum TextInserter {
    static func insert(_ text: String, mode: OutputMode, restoreClipboard: Bool) {
        let pasteboard = NSPasteboard.general
        switch mode {
        case .historyOnly:
            return
        case .copy:
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        case .paste, .pasteAndSend:
            let saved = restoreClipboard ? snapshot(pasteboard) : nil
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            // Marque le contenu comme transitoire pour les gestionnaires de presse-papiers.
            pasteboard.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
            let changeCount = pasteboard.changeCount

            guard AXIsProcessTrusted() else { return } // sans Accessibilité, le texte reste copié
            postKey(UInt16(kVK_ANSI_V), flags: .maskCommand)
            if mode == .pasteAndSend {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { postKey(UInt16(kVK_Return), flags: []) }
            }
            if let saved {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    // Ne restaure pas si l'utilisateur a copié autre chose entre-temps.
                    guard pasteboard.changeCount == changeCount else { return }
                    restore(saved, to: pasteboard)
                }
            }
        }
    }

    /// Le curseur est-il dans un champ où coller ? true : oui ; false : sûrement pas (bureau, liste,
    /// page web sans champ actif) ; nil : impossible à dire, l'app n'expose pas son interface. Dans le doute, on colle.
    static func focusedFieldAcceptsText() -> Bool? {
        guard AXIsProcessTrusted() else { return false }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.25)
        var focused: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused)
        guard error == .success, let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            // Rien n'a le focus : c'est sûr seulement si l'app au premier plan n'a pas non plus de fenêtre active
            // (bureau, app sans fenêtre). Sinon l'app n'expose simplement pas son interface (Zed, Ghostty…).
            guard error == .noValue, let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.25)
            var window: CFTypeRef?
            let windowError = AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window)
            return windowError == .noValue ? false : nil
        }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.25)
        let role = attribute(element, kAXRoleAttribute) as? String ?? ""
        if textRoles.contains(role) { return true }
        // Chromium et Electron : un élément dans une zone éditable (contenteditable) l'indique ainsi.
        if attribute(element, "AXEditableAncestor") != nil { return true }
        if nonTextRoles.contains(role) { return false }
        return nil
    }

    private static let textRoles: Set<String> = [
        kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, "AXSearchField",
    ]
    private static let nonTextRoles: Set<String> = [
        kAXListRole, kAXOutlineRole, kAXTableRole, kAXBrowserRole, kAXButtonRole, kAXImageRole, kAXRowRole,
        kAXCellRole, kAXCheckBoxRole, kAXRadioButtonRole, kAXPopUpButtonRole, kAXMenuButtonRole, kAXSliderRole,
        kAXStaticTextRole, kAXScrollAreaRole, kAXTabGroupRole, kAXToolbarRole, "AXWebArea", "AXLink",
    ]

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private static func postKey(_ key: UInt16, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    private static func snapshot(_ pb: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pb.pasteboardItems ?? []).map { item in
            var dict: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types { if let data = item.data(forType: type) { dict[type] = data } }
            return dict
        }
    }

    private static func restore(_ items: [[NSPasteboard.PasteboardType: Data]], to pb: NSPasteboard) {
        pb.clearContents()
        guard !items.isEmpty else { return }
        let restored = items.map { dict -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in dict { item.setData(data, forType: type) }
            return item
        }
        pb.writeObjects(restored)
    }
}

/// Remplacements de mots et nettoyage léger, appliqués après la transcription.
enum TextProcessing {
    static func apply(_ text: String, replacements: [WordReplacement]) -> String {
        var out = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for r in replacements where !r.from.isEmpty {
            let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: r.from) + "(?![\\p{L}\\p{N}])"
            let options: NSRegularExpression.Options = r.caseSensitive ? [] : [.caseInsensitive]
            if let regex = try? NSRegularExpression(pattern: pattern, options: options) {
                out = regex.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out),
                                                     withTemplate: NSRegularExpression.escapedTemplate(for: r.to))
            }
        }
        // Whisper produit parfois ces marqueurs sur du silence.
        for junk in ["[BLANK_AUDIO]", "[Musique]", "[Music]", "(silence)"] {
            out = out.replacingOccurrences(of: junk, with: "")
        }
        while out.contains("  ") { out = out.replacingOccurrences(of: "  ", with: " ") }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Retire les hésitations (euh, hum, uh…) et les mots répétés par erreur (« le le »),
    /// sauf les doublons légitimes du français (« nous nous », « vous vous »).
    static func removeFillers(_ text: String) -> String {
        var out = text
        let fillers = "(?i)(?<![\\p{L}\\p{N}])(euh+|heu+|hum+|hmm+|uh+|um+|erm)(?![\\p{L}\\p{N}])[,.…]?\\s*"
        out = out.replacingOccurrences(of: fillers, with: "", options: .regularExpression)
        if let regex = try? NSRegularExpression(pattern: "(?i)(?<![\\p{L}\\p{N}])(?!(?:nous|vous)\\b)(\\p{L}+)(\\s+\\1)+(?![\\p{L}\\p{N}])") {
            out = regex.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "$1")
        }
        // Répétitions de deux ou trois mots : « on peut on peut » → « on peut ».
        if let regex = try? NSRegularExpression(pattern: "(?i)(?<![\\p{L}\\p{N}])(\\p{L}+(?:['’\\s]+\\p{L}+){1,2})(\\s+\\1)+(?![\\p{L}\\p{N}])") {
            out = regex.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "$1")
        }
        out = out.replacingOccurrences(of: "\\s+([,.])", with: "$1", options: .regularExpression)
        out = out.replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
        if let first = out.first, first.isLowercase, text.first?.isUppercase == true {
            out = first.uppercased() + out.dropFirst()
        }
        // Une hésitation retirée en début de phrase laissait la phrase sans majuscule.
        if let regex = try? NSRegularExpression(pattern: "([.!?…]\\s+)(\\p{Ll})") {
            for m in regex.matches(in: out, range: NSRange(out.startIndex..., in: out)).reversed() {
                if let r = Range(m.range(at: 2), in: out) { out.replaceSubrange(r, with: out[r].uppercased()) }
            }
        }
        return out
    }

    static func wordCount(_ text: String) -> Int {
        text.split { $0.isWhitespace || $0.isNewline }.count
    }
}
