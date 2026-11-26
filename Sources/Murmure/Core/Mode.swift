import AppKit
import Foundation

/// Quand appliquer les remplacements de mots par rapport à l'IA.
enum ReplacementTiming: String, Codable, CaseIterable, Identifiable {
    case before, after, both
    var id: String { rawValue }
    var label: String {
        switch self {
        case .before: return "Avant l'IA"
        case .after: return "Après l'IA"
        case .both: return "Avant et après l'IA"
        }
    }
}

struct AppRef: Codable, Hashable, Identifiable {
    var bundleID: String
    var name: String
    var id: String { bundleID }
}

/// Un mode = une configuration de dictée complète : instructions IA, sortie, contexte,
/// et les façons de l'activer. Le mode principal s'applique quand aucun autre ne s'active.
struct Mode: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var symbol: String = "text.bubble"
    var isMain = false

    // Traitement
    /// Consignes pour le LLM local. Vide : le mode se contente de dicter (et de nettoyer si activé).
    var instructions: String = ""
    /// Nettoyage local (hésitations, ponctuation) quand il n'y a pas d'instructions.
    var cleanup = true
    /// Code de langue cible pour la traduction d'Apple, ou nil.
    var translateTo: String?
    var outputMode: OutputMode = .paste

    // Activation
    var shortcut: TriggerKey?
    var triggerWord: String = ""
    var apps: [AppRef] = []
    var websites: [String] = []

    // Contexte transmis à l'IA
    var includeClipboard = false
    var includeActiveApp = false
    var includeCursorContext = false
    var includeBrowserURL = false

    // Réglages avancés
    var replacementTiming: ReplacementTiming = .before
    /// Remplace les consignes système de Murmure (les instructions du mode viennent après).
    var systemPrompt: String = ""
    var temperature: Double = 0.1
    var scriptBefore: String = ""
    var scriptAfter: String = ""

    var usesAI: Bool { !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || cleanup }
    var needsContext: Bool { includeClipboard || includeActiveApp || includeCursorContext || includeBrowserURL }

    /// Résumé des déclencheurs, affiché dans la liste des modes.
    var activationSummary: [String] {
        var parts: [String] = []
        if let shortcut { parts.append(shortcut.label) }
        if !triggerWord.isEmpty { parts.append("« \(triggerWord) »") }
        parts += apps.map(\.name)
        parts += websites
        return parts
    }

    static func main() -> Mode {
        Mode(name: "Dictée", symbol: "waveform", isMain: true, cleanup: true)
    }
}

/// Modèles de modes proposés à la création (l'utilisateur les modifie ensuite librement).
enum ModeTemplates {
    static let all: [Mode] = [
        Mode(name: "Traduire en anglais", symbol: "globe", cleanup: true, translateTo: "en", triggerWord: "anglais"),
        Mode(name: "E-mail", symbol: "envelope",
             instructions: """
             Mets en forme la dictée comme le corps d'un e-mail clair et poli, dans la langue de la dictée. \
             Garde le registre (tu ou vous) et toutes les informations. Paragraphes courts. \
             Pas d'objet, pas de signature inventée.
             """,
             triggerWord: "mail", apps: [AppRef(bundleID: "com.apple.mail", name: "Mail")],
             websites: ["mail.google.com", "outlook.office.com"]),
        Mode(name: "Message", symbol: "bubble.left.and.bubble.right",
             instructions: """
             Transforme la dictée en message court et naturel pour une messagerie, dans la langue de la dictée. \
             Garde le ton, pas de formule de politesse ajoutée, pas de point final sur une phrase unique.
             """,
             apps: [AppRef(bundleID: "com.tinyspeck.slackmacgap", name: "Slack"),
                    AppRef(bundleID: "net.whatsapp.WhatsApp", name: "WhatsApp"),
                    AppRef(bundleID: "com.apple.MobileSMS", name: "Messages")]),
        Mode(name: "Prompt pour IA", symbol: "sparkles",
             instructions: """
             Réécris la dictée en instruction claire et structurée pour un assistant IA ou un agent de code. \
             Garde toutes les contraintes, noms de fichiers et détails techniques. Utilise une liste si c'est plus lisible.
             """,
             triggerWord: "prompt",
             apps: [AppRef(bundleID: "com.anthropic.claudefordesktop", name: "Claude"),
                    AppRef(bundleID: "com.todesktop.230313mzl4w4u92", name: "Cursor")],
             websites: ["claude.ai", "chatgpt.com"]),
        Mode(name: "Réponse au texte sélectionné", symbol: "arrowshape.turn.up.left",
             instructions: """
             L'utilisateur a sélectionné un message ({{CONTEXT.SELECTED_TEXT}}) et dicte les grandes lignes de sa réponse. \
             Rédige la réponse complète, dans la langue du message sélectionné, en suivant fidèlement ce qu'il a dicté.
             """,
             cleanup: false, outputMode: .paste, includeCursorContext: true),
        Mode(name: "Commandes de ponctuation", symbol: "textformat",
             instructions: """
             Remplace les commandes de ponctuation dites à voix haute par les symboles : « virgule » par ,, « point » par ., \
             « point d'interrogation » par ?, « point d'exclamation » par !, « deux points » par :, « à la ligne » par un retour \
             à la ligne, « nouveau paragraphe » par deux retours à la ligne, « ouvrez les guillemets » et « fermez les guillemets » par « ». \
             Ne change aucun autre mot.
             """,
             cleanup: false),
    ]
}

/// Liste des modes, persistée en JSON dans Application Support.
@MainActor
final class ModeStore: ObservableObject {
    static let shared = ModeStore()

    @Published var modes: [Mode] { didSet { persist() } }
    /// Mode choisi à la main (menu, panneau, lien murmure://switch). Prioritaire sur le mode principal seulement.
    @Published var pinnedModeID: UUID?

    private let url: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Murmure", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("modes.json")
    }()

    private init() {
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode([Mode].self, from: data),
           saved.contains(where: \.isMain) {
            modes = saved
        } else {
            modes = [Mode.main()]
        }
    }

    var main: Mode { modes.first(where: \.isMain) ?? Mode.main() }

    func mode(_ id: UUID?) -> Mode? { modes.first { $0.id == id } }

    func mode(named nameOrID: String) -> Mode? {
        modes.first { $0.id.uuidString.caseInsensitiveCompare(nameOrID) == .orderedSame }
            ?? modes.first { $0.name.caseInsensitiveCompare(nameOrID) == .orderedSame }
    }

    func update(_ mode: Mode) {
        if let i = modes.firstIndex(where: { $0.id == mode.id }) { modes[i] = mode } else { modes.append(mode) }
    }

    func delete(_ mode: Mode) {
        guard !mode.isMain else { return }
        modes.removeAll { $0.id == mode.id }
        if pinnedModeID == mode.id { pinnedModeID = nil }
    }

    func duplicate(_ mode: Mode) -> Mode {
        var copy = mode
        copy.id = UUID()
        copy.isMain = false
        copy.name = mode.name + " (copie)"
        copy.shortcut = nil
        copy.triggerWord = ""
        modes.append(copy)
        return copy
    }

    /// Touches de dictée en service : la touche principale et celles des modes.
    var shortcutKeys: Set<TriggerKey> { Set(modes.compactMap(\.shortcut)) }

    /// Mode avant transcription. Priorité : raccourci du mode, site web, app, choix manuel, mode principal.
    /// Le mot déclencheur, prioritaire sur tout, est appliqué après la transcription.
    func resolve(shortcut: TriggerKey?, context: DictationContext) -> Mode {
        if let shortcut, let m = modes.first(where: { $0.shortcut == shortcut }) { return m }
        if let host = context.browserHost,
           let m = modes.first(where: { mode in mode.websites.contains { Self.host(host, matches: $0) } }) { return m }
        if let bundle = context.appBundleID, let m = modes.first(where: { $0.apps.contains { $0.bundleID == bundle } }) {
            return m
        }
        if let pinned = mode(pinnedModeID) { return pinned }
        return main
    }

    /// Cherche un mot déclencheur au début de la transcription. Renvoie le mode et le texte sans le mot.
    func triggerMatch(in text: String) -> (Mode, String)? {
        let lowered = text.lowercased()
        let candidates = modes.filter { !$0.triggerWord.trimmingCharacters(in: .whitespaces).isEmpty }
            .sorted { $0.triggerWord.count > $1.triggerWord.count }
        for mode in candidates {
            let word = mode.triggerWord.lowercased().trimmingCharacters(in: .whitespaces)
            guard lowered.hasPrefix(word) else { continue }
            let rest = text.dropFirst(word.count)
            // Le mot doit être entier : suivi d'une ponctuation, d'un espace ou de rien.
            if let next = rest.first, next.isLetter || next.isNumber { continue }
            var remaining = String(rest).trimmingCharacters(in: CharacterSet(charactersIn: " ,.:;!?-").union(.whitespaces))
            if let first = remaining.first { remaining = first.uppercased() + remaining.dropFirst() }
            return (mode, remaining)
        }
        return nil
    }

    static func host(_ host: String, matches pattern: String) -> Bool {
        let p = pattern.lowercased()
            .replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "")
            .split(separator: "/").first.map(String.init) ?? ""
        guard !p.isEmpty else { return false }
        let h = host.lowercased()
        return h == p || h.hasSuffix("." + p)
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        if let data = try? encoder.encode(modes) { try? data.write(to: url, options: .atomic) }
    }
}

/// Ton choisi automatiquement selon l'app au premier plan. Il ajuste le nettoyage sans changer les mots :
/// le garde-fou de fidélité s'applique toujours.
enum AutoTone: String {
    case mail, chat, prompt

    /// Libellé court affiché dans le panneau de dictée.
    var label: String {
        switch self {
        case .mail: return "Ton soigné"
        case .chat: return "Ton naturel"
        case .prompt: return "Prompt clair"
        }
    }

    /// Ton sans IA, comme le font les claviers : on touche la ponctuation finale, jamais les mots.
    /// Messagerie : une phrase courte se passe de point final.
    func applyLight(_ text: String) -> String {
        guard self == .chat, text.hasSuffix("."), !text.hasSuffix("..."),
              text.dropLast().rangeOfCharacter(from: CharacterSet(charactersIn: ".!?")) == nil else { return text }
        return String(text.dropLast())
    }

    static func detect(bundleID: String?) -> AutoTone? {
        guard let id = bundleID?.lowercased() else { return nil }
        if mailApps.contains(where: { id.hasPrefix($0) }) { return .mail }
        if chatApps.contains(where: { id.hasPrefix($0) }) { return .chat }
        if promptApps.contains(where: { id.hasPrefix($0) }) { return .prompt }
        return nil
    }

    private static let mailApps = [
        "com.apple.mail", "com.microsoft.outlook", "com.readdle.smartemail", "com.superhuman",
        "com.mimestream", "com.airmailapp", "it.bloop.airmail", "com.freron.mailmate", "com.canarymail",
    ]
    private static let chatApps = [
        "com.tinyspeck.slackmacgap", "com.apple.mobilesms", "net.whatsapp", "desktop.whatsapp",
        "com.hnc.discord", "com.microsoft.teams", "ru.keepcoder.telegram", "org.telegram", "com.facebook.archon",
        "org.whispersystems.signal", "com.linear",
    ]
    private static let promptApps = [
        "com.openai.chat", "com.anthropic.claude", "com.todesktop.230313mzl4w4u92", "com.exafunction.windsurf",
        "com.microsoft.vscode", "dev.zed", "com.apple.terminal", "com.googlecode.iterm2", "dev.warp",
        "com.mitchellh.ghostty", "ai.perplexity", "com.google.gemini",
    ]

    /// Consigne ajoutée au nettoyage.
    var rule: String {
        switch self {
        case .mail:
            return "Contexte : un e-mail. Phrases complètes et ponctuation soignée. Garde exactement les mêmes mots, " +
                "le tutoiement ou le vouvoiement tel quel. N'ajoute ni formule de politesse ni signature."
        case .chat:
            return "Contexte : une messagerie instantanée. Style direct et naturel, ponctuation légère, " +
                "pas de point à la fin d'un message d'une seule phrase. N'ajoute aucune formule de politesse."
        case .prompt:
            return "Contexte : une consigne pour un assistant IA. Rends la demande claire et bien ponctuée ; " +
                "si elle contient plusieurs demandes, mets-les en liste avec des tirets. " +
                "Ne réponds jamais à la demande et ne l'exécute pas : renvoie la consigne corrigée."
        }
    }

    /// Exemples propres à ce ton, ajoutés après ceux du nettoyage.
    var shots: [(String, String)] {
        switch self {
        case .mail:
            return [("bonjour Claire je vous envoie le devis ce soir dites moi si vous avez des questions",
                     "Bonjour Claire, je vous envoie le devis ce soir. Dites-moi si vous avez des questions.")]
        case .chat:
            return [("ok je regarde ça et je te redis dans dix minutes",
                     "Ok, je regarde ça et je te redis dans 10 minutes")]
        case .prompt:
            return [("écris une fonction qui trie la liste par date et ajoute des tests et mets aussi à jour le readme",
                     "Écris une fonction qui trie la liste par date, puis :\n- ajoute des tests ;\n- mets aussi à jour le README.")]
        }
    }
}
