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
    /// Modèle chargé en mémoire et prêt à répondre.
    private var ready = false

    private init() {}

    var modelPath: String { Self.overridePath ?? ai.path(for: .cleanup).path }

    var isInstalled: Bool {
        Self.overridePath.map { FileManager.default.fileExists(atPath: $0) } ?? ai.installed.contains(LocalLLM.cleanup.id)
    }

    /// Charge le modèle en mémoire (environ 0,5 Go) dès le lancement : la première dictée n'attend pas.
    func warmUp() {
        guard isInstalled, loading == nil else { return }
        let path = modelPath
        let runner = runner
        let task = Task { try await runner.load(path: path, contextSize: 2048) }
        loading = task
        Task { [weak self] in
            do { try await task.value; self?.ready = true } catch { self?.loading = nil }
        }
    }

    /// Attend la fin du chargement (bancs de test). Faux si le modèle ne se charge pas.
    func waitUntilReady() async -> Bool {
        warmUp()
        guard let loading else { return false }
        do { try await loading.value; ready = true; return true } catch { self.loading = nil; return false }
    }

    func unload() {
        loading = nil
        ready = false
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
        // Encore en chargement (premier lancement) : on n'attend pas, les règles suffisent cette fois.
        guard ready else { warmUp(); return fallback("modèle en cours de chargement") }
        let deadline = Date().addingTimeInterval(Self.timeout)
        let messages: [(role: String, content: String)] = [("system", Self.systemPrompt), ("user", input)]
        // La sortie est au plus aussi longue que l'entrée (les nombres et adresses raccourcissent).
        let maxTokens = Int(Double(input.count) / 2.2) + 24
        let output: String
        do {
            output = try await runner.generateCopying(messages: messages, maxTokens: maxTokens, deadline: deadline)
        } catch {
            return fallback(error.localizedDescription)
        }
        if await runner.lastIncomplete { return fallback("sortie tronquée") }
        let cleaned = Self.repair(output: output.trimmingCharacters(in: .whitespacesAndNewlines), input: input)
        if let problem = Self.guardProblem(output: cleaned, input: input) { return fallback(problem) }
        return Result(text: cleaned, usedModel: true, fallbackReason: "", seconds: Date().timeIntervalSince(started))
    }

    // MARK: Garde-fou (identique à training/cleanup-1/evaluate.py)

    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// Suites de lettres de `s` qui ne suivent pas un chiffre (« 15h », « 1er » ne comptent pas),
    /// avec leur position dans la chaîne.
    static func letterRuns(_ s: String) -> [(word: String, range: Range<String.Index>)] {
        var runs: [(String, Range<String.Index>)] = []
        var start: String.Index?
        var afterDigit = false
        var i = s.startIndex
        var previous: Character?
        while i < s.endIndex {
            let ch = s[i]
            if ch.isLetter {
                if start == nil { start = i; afterDigit = previous?.isNumber == true }
            } else if let st = start {
                if !afterDigit { runs.append((String(s[st..<i]), st..<i)) }
                start = nil
            }
            previous = ch
            i = s.index(after: i)
        }
        if let st = start, !afterDigit { runs.append((String(s[st..<s.endIndex]), st..<s.endIndex)) }
        return runs
    }

    /// Mots de lettres, en minuscules et sans accents.
    static func letterWords(_ s: String) -> [String] { letterRuns(s).map { fold($0.word) } }

    static func editDistance(_ a: [Character], _ b: [Character]) -> Int {
        var prev = Array(0...b.count)
        for i in 1...max(1, a.count) where !a.isEmpty {
            var cur = [i] + Array(repeating: 0, count: b.count)
            for j in stride(from: 1, through: b.count, by: 1) {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return a.isEmpty ? b.count : prev[b.count]
    }

    private static func joinedWords(_ a: [String]) -> Set<String> {
        var set = Set(a)
        for i in a.indices.dropLast() { set.insert(a[i] + a[i + 1]) }
        for i in a.indices.dropLast(2) { set.insert(a[i] + a[i + 1] + a[i + 2]) }
        return set
    }

    /// Un mot de sortie absent de la dictée mais à une ou deux lettres d'un mot dicté est une coquille du
    /// modèle (« Envoye » pour « envoie ») : on remet le mot dicté, avec la majuscule de la sortie.
    static func repair(output: String, input: String) -> String {
        var originals: [String: String] = [:]
        var order: [String] = []
        for run in letterRuns(input) {
            let f = fold(run.word)
            if originals[f] == nil { originals[f] = run.word; order.append(f) }
        }
        let known = joinedWords(letterWords(input))
        var result = output
        for run in letterRuns(output).reversed() {
            let f = fold(run.word)
            guard f.count >= 3, !known.contains(f) else { continue }
            let fc = Array(f)
            var best: String?
            var bestDistance = 3
            for c in order {
                let cc = Array(c)
                let similar = (abs(cc.count - fc.count) <= 2 && cc.first == fc.first)
                    || (fc.count > 3 && cc.count > 3 && cc[1...2] == fc[1...2])
                guard similar else { continue }
                let d = editDistance(fc, cc)
                if d < bestDistance, d <= max(1, cc.count / 3) { best = c; bestDistance = d }
            }
            guard let best, let original = originals[best] else { continue }
            let replacement = run.word.first?.isUppercase == true ? original.prefix(1).uppercased() + original.dropFirst() : original
            result.replaceSubrange(run.range, with: replacement)
        }
        return result
    }

    // Mots-nombres (sans accents). « un », « une » sont aussi des articles : l'ensemble des valeurs permises
    // est volontairement large, on veut attraper « 15 000 » devenu « 1 500 ».
    static let units: [String: Int] = [
        "zero": 0, "un": 1, "une": 1, "deux": 2, "trois": 3, "quatre": 4, "cinq": 5, "six": 6, "sept": 7,
        "huit": 8, "neuf": 9, "dix": 10, "onze": 11, "douze": 12, "treize": 13, "quatorze": 14, "quinze": 15,
        "seize": 16, "vingt": 20, "vingts": 20, "trente": 30, "quarante": 40, "cinquante": 50, "soixante": 60,
        "premier": 1, "premiere": 1, "midi": 12, "minuit": 0, "demie": 30, "demi": 30, "quart": 15,
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
        "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16,
        "seventeen": 17, "eighteen": 18, "nineteen": 19, "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
        "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90, "oh": 0, "noon": 12, "midnight": 0,
        "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6, "seventh": 7, "eighth": 8,
        "ninth": 9, "tenth": 10, "eleventh": 11, "twelfth": 12, "thirteenth": 13, "fourteenth": 14,
        "fifteenth": 15, "sixteenth": 16, "seventeenth": 17, "eighteenth": 18, "nineteenth": 19,
        "twentieth": 20, "thirtieth": 30, "half": 30, "quarter": 15,
    ]
    static let scales: [String: Int] = [
        "cent": 100, "cents": 100, "hundred": 100, "mille": 1_000, "thousand": 1_000, "k": 1_000,
        "million": 1_000_000, "millions": 1_000_000, "milliard": 1_000_000_000, "milliards": 1_000_000_000,
        "billion": 1_000_000_000,
    ]
    /// Mots qu'on retire légitimement : hésitations, marqueurs de correction, unités devenues symboles.
    static let droppable: Set<String> = [
        "euh", "heu", "hum", "hmm", "bah", "ben", "genre", "hein", "um", "uh", "uhm", "er", "erm", "like",
        "enfin", "non", "pardon", "plutot", "attends", "veux", "dire", "trompe", "fait", "mean", "sorry",
        "no", "wait", "actually", "rather", "scratch", "that", "heures", "heure", "euros", "euro", "pour",
        "percent", "dollars", "dollar", "pounds", "virgule", "point", "dot", "arobase", "at", "slash",
        "tiret", "dash", "hyphen", "underscore", "bas", "pm", "am", "clock", "vois", "know", "you", "tu",
    ]

    /// Toutes les valeurs que la dictée peut désigner : chiffres écrits et suites de mots-nombres.
    static func spokenNumbers(_ input: String) -> Set<Int> {
        var values = Set<Int>()
        for m in digitGroups(input, thousandsWithDot: true) {
            values.insert(m.value)
            for part in m.parts {
                values.insert(part)
            }
        }
        // Numéro dicté d'un bloc : « 0612345678 » → 06 12 34 56 78.
        for run in input.split(whereSeparator: { !$0.isNumber }) where run.count >= 7 {
            let digits = Array(run)
            for k in 1...4 {
                for i in 0...(digits.count - k) { if let v = Int(String(digits[i..<i + k])) { values.insert(v) } }
            }
        }
        // Une hésitation au milieu d'un nombre ne le coupe pas : « one hundred, uh, and forty ».
        let text = input.replacingOccurrences(
            of: "(?i)[,\\s]*(?<![\\p{L}])(euh+|heu+|hum+|hmm+|bah|ben|uh+|um+|uhm|er)(?![\\p{L}])[,\\s]*",
            with: " ", options: .regularExpression)
        // Mots et ponctuation (la ponctuation coupe les suites).
        var tokens: [String] = []
        var word = ""
        for ch in fold(text) {
            if ch.isLetter || ch.isNumber { word.append(ch); continue }
            if !word.isEmpty { tokens.append(word); word = "" }
            if ",.;:!?".contains(ch) { tokens.append(String(ch)) }
        }
        if !word.isEmpty { tokens.append(word) }
        var total = 0, current = 0, active = false
        func flush() {
            if active { values.insert(total + current) }
            total = 0; current = 0; active = false
        }
        for w in tokens {
            if let v = units[w] {
                values.insert(v)
                let r = current % 100
                if (w == "vingt" || w == "vingts"), r == 4 {
                    current += 76                       // quatre-vingt
                } else if !active || r == 0 || (r % 10 == 0 && v < 10) || ((r == 60 || r == 80) && (10...19).contains(v)) {
                    current += v                        // vingt et un, soixante-dix, cent deux…
                } else {
                    flush()                             // « trente-quatre cinquante-six » : deux nombres
                    current = v
                }
                active = true
                values.insert(total + current)
            } else if let scale = scales[w] {
                values.insert(scale)
                if scale == 100 {
                    current = max(current, 1) * 100
                } else {
                    total += max(current, 1) * scale
                    current = 0
                }
                active = true
                values.insert(total + current)
            } else if (w == "et" || w == "and"), active {
                continue
            } else {
                flush()
            }
        }
        flush()
        return values
    }

    /// Nombres écrits en chiffres : « 12 000 », « 15,000 » et « 1 500 » comptent pour un seul nombre.
    static func digitGroups(_ s: String, thousandsWithDot: Bool = false) -> [(value: Int, parts: [Int])] {
        let seps = thousandsWithDot ? " ,.\u{202F}\u{00A0}" : " ,\u{202F}\u{00A0}"
        let pattern = "\\d{1,3}(?:[\(seps)]\\d{3})+(?!\\d)|\\d+"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap { m in
            guard let r = Range(m.range, in: s) else { return nil }
            let text = String(s[r])
            let parts = text.split { !$0.isNumber }.compactMap { Int($0) }
            guard let value = Int(text.filter(\.isNumber).prefix(15)) else { return nil }
            return (value, parts)
        }
    }

    /// Nil si la sortie est un nettoyage plausible de l'entrée ; sinon, la raison du refus.
    static func guardProblem(output: String, input: String) -> String? {
        if output.isEmpty { return "sortie vide" }
        let a = letterWords(input), b = letterWords(output)
        // Un mot nouveau signale une réponse, une traduction ou une reformulation. Deux ou trois mots
        // dictés recollés (« git hub » → « GitHub ») ne sont pas nouveaux.
        let source = joinedWords(a)
        let novel = b.filter { !source.contains($0) }
        if novel.count > b.count / 20 { return "mots nouveaux : " + novel.prefix(5).joined(separator: " ") }
        // Chaque nombre écrit doit venir de la dictée, en chiffres ou en lettres.
        let allowed = spokenNumbers(input)
        let wrong = digitGroups(output).map(\.value).filter { !allowed.contains($0) }
        if !wrong.isEmpty { return "nombre inventé : " + wrong.prefix(3).map(String.init).joined(separator: " ") }
        if Double(output.count) > Double(input.count) * 1.25 + 12 { return "sortie trop longue" }
        let content = a.filter { !droppable.contains($0) && units[$0] == nil && scales[$0] == nil && $0.count > 1 }
        let kept = b.filter { units[$0] == nil && scales[$0] == nil }
        if content.count >= 4, Double(kept.count) < Double(content.count) * 0.5 { return "sortie trop courte" }
        // La fin de la dictée ne doit pas disparaître (sortie coupée trop tôt).
        if let last = content.last, !b.contains(last), !b.joined().contains(last) { return "fin perdue : \(last)" }
        return nil
    }
}
