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

    static func wordCount(_ text: String) -> Int {
        text.split { $0.isWhitespace || $0.isNewline }.count
    }
}
