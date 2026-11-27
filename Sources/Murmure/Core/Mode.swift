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

struct ModeExample: Codable, Hashable {
    var input: String
    var output: String
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
    /// Code de langue cible de la traduction (Apple si la langue est déjà sur le Mac, sinon le LLM local), ou nil.
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

    /// Exemples (dictée, résultat) montrés à l'IA avant la dictée : un petit modèle local les suit
    /// bien mieux que des règles écrites. Optionnel pour relire les modes enregistrés avant leur ajout.
    var examples: [ModeExample]?

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
/// Un mode s'active par sa touche : les modèles n'ont ni mot déclencheur ni app associée.
enum ModeTemplates {
    static let all: [Mode] = [
        Mode(name: "E-mail", symbol: "envelope",
             instructions: """
             Transforme la dictée en e-mail, dans la langue de la dictée. \
             Garde exactement le sens et toutes les informations : n'ajoute rien, n'interprète pas. \
             Trois parties séparées par une ligne vide : la salutation, le corps en paragraphes courts, la formule de fin. \
             Reprends la salutation dictée, sinon « Bonjour, ». Garde le tutoiement ou le vouvoiement. \
             Formule de fin : « À plus, » si la dictée tutoie, « Bien à vous, » si elle vouvoie. \
             Rien après la formule de fin : ni nom, ni signature. Pas d'objet.
             """,
             examples: [
                ModeExample(input: "salut Léa je t'envoie les photos ce soir et on se cale un appel demain ça te va",
                            output: "Salut Léa,\n\nJe t'envoie les photos ce soir. On se cale un appel demain, ça te va ?\n\nÀ plus,"),
                ModeExample(input: "bonjour monsieur Petit je n'ai pas encore reçu votre contrat est-ce que vous pouvez me le renvoyer merci",
                            output: "Bonjour Monsieur Petit,\n\nJe n'ai pas encore reçu votre contrat. Pourriez-vous me le renvoyer ?\n\nMerci et bien à vous,"),
                ModeExample(input: "coucou Sam tu viens toujours samedi",
                            output: "Coucou Sam,\n\nTu viens toujours samedi ?\n\nÀ plus,"),
                ModeExample(input: "je vous relance pour le paiement de la facture de septembre on l'a pas encore reçu",
                            output: "Bonjour,\n\nJe me permets de vous relancer pour le paiement de la facture de septembre, que nous n'avons pas encore reçu.\n\nBien à vous,"),
             ]),
        Mode(name: "Prompt pour IA", symbol: "sparkles",
             instructions: """
             Réécris la dictée en consigne claire pour un assistant IA ou un agent de code. \
             Garde toutes les contraintes, noms de fichiers et détails techniques. \
             S'il y a plusieurs demandes, mets-les en liste à tirets. N'exécute pas la consigne et n'y réponds pas.
             """,
             examples: [
                ModeExample(input: "corrige le bug du bouton de connexion qui marche pas sur safari et ajoute un test et mets à jour le changelog",
                            output: "Corrige le bug du bouton de connexion, qui ne fonctionne pas sur Safari. Ensuite :\n- ajoute un test ;\n- mets à jour le CHANGELOG."),
                ModeExample(input: "explique moi la différence entre une promesse et un observable en javascript",
                            output: "Explique-moi la différence entre une promesse et un observable en JavaScript."),
             ]),
        Mode(name: "Message", symbol: "bubble.left.and.bubble.right",
             instructions: """
             Remets la dictée en forme pour un message (SMS, WhatsApp, Slack), dans la langue de la dictée. \
             Reformule les phrases mal construites pour qu'elles se lisent bien : remets la syntaxe d'aplomb, \
             coupe les phrases qui s'enchaînent sans fin, retire les répétitions et les tics de langage \
             (« en fait », « du coup », « genre », « voilà ») qui n'apportent rien, et relie les idées dans un ordre logique. \
             Garde un ton oral et détendu : ne remplace jamais un mot familier par un mot soutenu \
             (« kiffer », « t'es », « mec », « truc » restent tels quels), tutoiement ou vouvoiement tel quel. \
             Garde tout le sens et toutes les informations, n'ajoute rien. Une question reste une question, \
             et une cause reste une cause : ne transforme pas un « parce que » en « donc ». \
             Pas de salutation ni de formule de fin si la dictée n'en a pas. \
             Si le message est long, sépare les idées en paragraphes courts. Pas de point final sur une phrase unique.
             """,
             examples: [
                ModeExample(input: "mec t'as vu le match hier soir c'était un truc de ouf",
                            output: "Mec, t'as vu le match hier soir ? C'était un truc de ouf"),
                ModeExample(input: "du coup on fait quoi ce soir on se capte chez toi ou on va direct au bar moi je m'en fiche",
                            output: "On fait quoi ce soir ? On se capte chez toi ou on va direct au bar ? Moi je m'en fiche"),
                ModeExample(input: "alors en fait je voulais te dire que le colis il est arrivé mais du coup il manque une pièce parce que le vendeur s'est planté",
                            output: "Le colis est arrivé, mais il manque une pièce parce que le vendeur s'est planté"),
                ModeExample(input: "ouais alors pour samedi en fait c'est bon pour moi mais du coup faut voir avec Julie parce que elle elle bosse le matin je crois enfin je suis pas sûr donc demande-lui et tu me dis",
                            output: "Ouais, samedi c'est bon pour moi ! Par contre faut voir avec Julie : je crois qu'elle bosse le matin, mais je suis pas sûr. Demande-lui et tu me dis"),
                ModeExample(input: "hello alors j'ai regardé le devis que tu m'as envoyé et globalement c'est bon le truc c'est que la partie hébergement elle est un peu chère enfin je trouve et aussi il manque la maintenance qu'on avait dit au téléphone donc est-ce que tu peux me renvoyer une version avec ça et on valide dans la foulée",
                            output: "Hello ! J'ai regardé le devis que tu m'as envoyé, globalement c'est bon.\n\nPar contre je trouve la partie hébergement un peu chère, et il manque la maintenance dont on avait parlé au téléphone. Tu peux me renvoyer une version avec ça ? On valide dans la foulée."),
             ]),
        translation,
    ]

    /// Dicter dans sa langue, coller dans une autre. La langue cible se choisit dans le mode.
    static let translation = Mode(name: "Traduction", symbol: "globe", cleanup: true, translateTo: "en")

    /// Ordre dans lequel les touches libres sont proposées aux nouveaux modes.
    static let keyOrder: [TriggerKey] = [.rightOption, .fn, .rightShift, .leftOption, .rightControl, .rightCommand]
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

    /// Crée un mode à partir d'un modèle (ou vide), avec la première touche libre.
    func add(from template: Mode?, mainKey: TriggerKey) -> Mode {
        var mode = template ?? Mode(name: "Nouveau mode", symbol: "text.bubble", instructions: "")
        mode.id = UUID()
        mode.isMain = false
        var name = mode.name, n = 2
        while modes.contains(where: { $0.name == name }) { name = "\(mode.name) \(n)"; n += 1 }
        mode.name = name
        let used = shortcutKeys.union([mainKey])
        mode.shortcut = ModeTemplates.keyOrder.first { !used.contains($0) }
        modes.append(mode)
        return mode
    }

    /// Mode qui utilise cette touche (hors mode principal, dont la touche est dans les réglages).
    func holder(of key: TriggerKey) -> Mode? { modes.first { !$0.isMain && $0.shortcut == key } }

    /// Attribue une touche à un mode. Si un autre mode l'avait, il récupère l'ancienne touche du mode.
    func assign(_ key: TriggerKey?, to id: UUID) {
        guard var mode = mode(id), !mode.isMain else { return }
        let previous = mode.shortcut
        if let key, var other = holder(of: key), other.id != id {
            other.shortcut = previous
            update(other)
        }
        mode.shortcut = key
        update(mode)
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
