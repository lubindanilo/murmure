import AppKit
import ApplicationServices
import Foundation

/// Ce qui entoure la dictée, capturé au moment où elle commence (l'utilisateur est encore dans son app).
struct DictationContext {
    var appName: String?
    var appBundleID: String?
    var selectedText: String?
    var textBeforeCursor: String?
    var textAfterCursor: String?
    var clipboard: String?
    var browserURL: String?

    var browserHost: String? { browserURL.flatMap { URL(string: $0)?.host } }

    static let browsers: [String: String] = [
        "com.apple.Safari": "safari",
        "com.apple.SafariTechnologyPreview": "safari",
        "com.google.Chrome": "chrome",
        "com.google.Chrome.canary": "chrome",
        "com.brave.Browser": "chrome",
        "com.microsoft.edgemac": "chrome",
        "company.thebrowser.Browser": "chrome",
        "com.vivaldi.Vivaldi": "chrome",
        "com.operasoftware.Opera": "chrome",
    ]

    /// Instantané : seulement l'app au premier plan (sert à choisir le mode dès l'appui).
    static func frontmost() -> DictationContext {
        var ctx = DictationContext()
        let app = NSWorkspace.shared.frontmostApplication
        ctx.appName = app?.localizedName
        ctx.appBundleID = app?.bundleIdentifier
        return ctx
    }

    /// Capture complète : app au premier plan, sélection, presse-papiers. Peut prendre du temps
    /// (accessibilité) : appelée hors du fil principal pendant la dictée.
    static func capture() -> DictationContext {
        var ctx = DictationContext()
        let app = NSWorkspace.shared.frontmostApplication
        ctx.appName = app?.localizedName
        ctx.appBundleID = app?.bundleIdentifier
        ctx.clipboard = NSPasteboard.general.string(forType: .string)
        if let app { exposeWebInterface(app) }
        readCursor(into: &ctx)
        return ctx
    }

    /// Chrome et les apps Electron (Slack, Notion, VS Code…) ne publient leur interface aux outils
    /// d'accessibilité que sur demande. Sans elle, Murmure ne saurait pas si le curseur est dans un champ.
    private static func exposeWebInterface(_ app: NSRunningApplication) {
        let chromium = app.bundleIdentifier.map { browsers[$0] == "chrome" } ?? false
        let electron = app.bundleURL.map {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("Contents/Frameworks/Electron Framework.framework").path)
        } ?? false
        guard chromium || electron, AXIsProcessTrusted() else { return }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.25)
        AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    /// Texte sélectionné et texte autour du curseur, via l'API d'accessibilité.
    private static func readCursor(into ctx: inout DictationContext) {
        guard AXIsProcessTrusted() else { return }
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused else { return }
        let el = element as! AXUIElement

        var selected: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, kAXSelectedTextAttribute as CFString, &selected) == .success,
           let s = selected as? String, !s.isEmpty {
            ctx.selectedText = s
        }

        var value: CFTypeRef?
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &value) == .success,
              let full = value as? String,
              AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rangeValue = rangeRef else { return }
        var range = CFRange()
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &range) else { return }
        let ns = full as NSString
        let start = max(0, min(range.location, ns.length))
        let end = max(start, min(range.location + range.length, ns.length))
        // On limite à 2 000 caractères de chaque côté pour garder le prompt court.
        let beforeStart = max(0, start - 2000)
        ctx.textBeforeCursor = ns.substring(with: NSRange(location: beforeStart, length: start - beforeStart))
        ctx.textAfterCursor = ns.substring(with: NSRange(location: end, length: min(2000, ns.length - end)))
    }

    /// URL de l'onglet actif (Safari et navigateurs Chromium). Demande l'autorisation d'automatisation.
    static func browserURL(bundleID: String?) async -> String? {
        guard let bundleID, let family = browsers[bundleID] else { return nil }
        let source = family == "safari"
            ? "tell application id \"\(bundleID)\" to return URL of front document"
            : "tell application id \"\(bundleID)\" to return URL of active tab of front window"
        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                var error: NSDictionary?
                let result = NSAppleScript(source: source)?.executeAndReturnError(&error).stringValue
                cont.resume(returning: result)
            }
        }
    }

    /// Valeurs exposées aux instructions ({{CONTEXT.X}}) et aux scripts (MURMURE_X).
    func values(for mode: Mode) -> [(key: String, label: String, value: String)] {
        var out: [(String, String, String)] = []
        if mode.includeActiveApp, let appName {
            out.append(("APP", "App active", appName))
        }
        if mode.includeCursorContext {
            if let selectedText { out.append(("SELECTED_TEXT", "Texte sélectionné", selectedText)) }
            if let textBeforeCursor, !textBeforeCursor.isEmpty {
                out.append(("TEXT_BEFORE_CURSOR", "Texte avant le curseur", textBeforeCursor))
            }
            if let textAfterCursor, !textAfterCursor.isEmpty {
                out.append(("TEXT_AFTER_CURSOR", "Texte après le curseur", textAfterCursor))
            }
        }
        if mode.includeClipboard, let clipboard, !clipboard.isEmpty {
            out.append(("CLIPBOARD", "Presse-papiers", String(clipboard.prefix(4000))))
        }
        if mode.includeBrowserURL, let browserURL { out.append(("URL", "URL de l'onglet actif", browserURL)) }
        return out
    }

    static let placeholderKeys = ["CONTEXT", "CONTEXT.APP", "CONTEXT.SELECTED_TEXT", "CONTEXT.TEXT_BEFORE_CURSOR",
                                  "CONTEXT.TEXT_AFTER_CURSOR", "CONTEXT.CLIPBOARD", "CONTEXT.URL"]
}
