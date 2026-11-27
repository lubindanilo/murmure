import Foundation

/// Murmure Cleanup 1 : petit modèle maison (Qwen 2.5 0.5B affiné, voir training/cleanup-1 et
/// docs/cleanup-1.md) qui nettoie la dictée simple : hésitations, répétitions, corrections dites
/// à voix haute, ponctuation, nombres en chiffres, adresses mail et sites. Il garde les mots dictés.
///
/// Repli sûr, comme Spokenly : si le modèle n'est pas installé, dépasse le délai, tronque sa sortie
/// ou s'éloigne trop du texte dicté, on garde le nettoyage par règles.
@MainActor
final class CleanupModel {
    static let shared = CleanupModel()

    /// Le prompt système vu à l'entraînement : il ne faut pas le changer sans réentraîner.
    static let systemPrompt = "Nettoie cette dictée."
    /// Au-delà, on garde les règles : la dictée ne doit jamais attendre.
    static var timeout: TimeInterval = 1.5
    /// Chemin imposé (tests : Murmure --cleanuptest … --cleanup-model fichier.gguf).
    static var overridePath: String?

    struct Result {
        let text: String
        let usedModel: Bool
        /// Pourquoi le modèle n'a pas été utilisé (vide sinon).
        let fallbackReason: String
        let seconds: TimeInterval
    }

    private let runner = LlamaRunner()
    private let ai = PostProcessor.shared
    private var loading: Task<Void, Error>?

    private init() {}

    var modelPath: String { Self.overridePath ?? ai.path(for: .cleanup).path }

    var isInstalled: Bool {
        Self.overridePath.map { FileManager.default.fileExists(atPath: $0) } ?? ai.installed.contains(LocalLLM.cleanup.id)
    }

    /// Charge le modèle en mémoire (environ 0,5 Go) pour que la première dictée soit rapide.
    func warmUp() {
        guard isInstalled, loading == nil else { return }
        let path = modelPath
        let runner = runner
        loading = Task { try await runner.load(path: path, contextSize: 2048) }
    }

    func unload() {
        loading = nil
        let runner = runner
        Task { await runner.unload() }
    }

    /// Nettoie une transcription brute. Ne lève jamais d'erreur : au pire, renvoie le résultat des règles.
    func clean(_ raw: String) async -> Result {
        let started = Date()
        let rules = TextProcessing.removeFillers(raw)
        func fallback(_ reason: String) -> Result {
            NSLog("Murmure Cleanup 1 : repli sur les règles (\(reason))")
            return Result(text: rules, usedModel: false, fallbackReason: reason, seconds: Date().timeIntervalSince(started))
        }
        let input = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return fallback("texte vide") }
        // Au-delà d'environ 600 mots, le contexte de 2 048 tokens ne suffit plus.
        guard input.count < 3_500 else { return fallback("texte trop long") }
        guard isInstalled else { return fallback("modèle absent") }
        warmUp()
        do {
            try await loading?.value
        } catch {
            loading = nil
            return fallback("chargement impossible")
        }
        // Délai compté depuis la fin du chargement : le premier chargement (une seule fois) ne pénalise pas.
        let deadline = Date().addingTimeInterval(Self.timeout)
        let messages: [(role: String, content: String)] = [("system", Self.systemPrompt), ("user", input)]
        // La sortie est au plus aussi longue que l'entrée (les nombres et adresses raccourcissent).
        let maxTokens = Int(Double(input.count) / 2.2) + 24
        let output: String
        do {
            output = try await runner.generate(messages: messages, maxTokens: maxTokens, deadline: deadline)
        } catch {
            return fallback(error.localizedDescription)
        }
        if await runner.lastIncomplete { return fallback("sortie tronquée") }
        let cleaned = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if let problem = Self.guardProblem(output: cleaned, input: input) { return fallback(problem) }
        return Result(text: cleaned, usedModel: true, fallbackReason: "", seconds: Date().timeIntervalSince(started))
    }

    // MARK: Garde-fou (identique à training/cleanup-1/evaluate.py)

    /// Mots de lettres, en minuscules et sans accents. Les lettres collées à un chiffre (« 15h », « 1er »)
    /// ne comptent pas : elles viennent de l'écriture des nombres.
    static func letterWords(_ s: String) -> [String] {
        let folded = s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        var words: [String] = []
        var current = ""
        var afterDigit = false
        var previous: Character?
        for ch in folded {
            if ch.isLetter {
                if current.isEmpty { afterDigit = previous?.isNumber == true }
                current.append(ch)
            } else {
                if !current.isEmpty, !afterDigit { words.append(current) }
                current = ""
            }
            previous = ch
        }
        if !current.isEmpty, !afterDigit { words.append(current) }
        return words
    }

    /// Nil si la sortie est un nettoyage plausible de l'entrée ; sinon, la raison du refus.
    /// Le modèle ne doit presque rien ajouter : un mot nouveau signale une réponse, une traduction
    /// ou une reformulation.
    static func guardProblem(output: String, input: String) -> String? {
        if output.isEmpty { return "sortie vide" }
        let a = letterWords(input), b = letterWords(output)
        // Deux ou trois mots dictés recollés (« git hub » → « GitHub ») ne sont pas nouveaux.
        var source = Set(a)
        for i in a.indices.dropLast() { source.insert(a[i] + a[i + 1]) }
        for i in a.indices.dropLast(2) { source.insert(a[i] + a[i + 1] + a[i + 2]) }
        let novel = b.filter { !source.contains($0) }
        if novel.count > b.count / 12 {
            return "mots nouveaux : " + novel.prefix(5).joined(separator: " ")
        }
        if Double(output.count) > Double(input.count) * 1.25 + 12 { return "sortie trop longue" }
        if a.count >= 4, Double(b.count) < Double(a.count) * 0.35 { return "sortie trop courte" }
        return nil
    }
}
