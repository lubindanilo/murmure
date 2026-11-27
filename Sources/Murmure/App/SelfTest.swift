import AVFoundation
import Foundation

/// Vérification de bout en bout sans micro ni interface :
///   Murmure --selftest fichier.wav [--model parakeet-v3] [--llm qwen2.5-1.5b] [--mode Nettoyage]
///   Murmure --cleanuptest dictees.txt|eval.jsonl [--cleanup-model fichier.gguf]
/// Télécharge les modèles si besoin, transcrit le fichier, le nettoie avec Murmure Cleanup 2,
/// puis applique l'IA locale si --llm est donné.
@MainActor
enum SelfTest {
    static func run(_ args: [String]) async -> Int32 {
        func value(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        let settings = Settings.shared
        if args.contains("--licensetest") { return await licenseTest() }
        // Murmure --addmode E-mail : ajoute un mode depuis un modèle, avec la première touche libre.
        if let name = value("--addmode") {
            guard let t = ModeTemplates.all.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
                print("Modèle de mode inconnu : \(name)"); return 2
            }
            let mode = ModeStore.shared.add(from: t, mainKey: settings.triggerKey)
            print("\(mode.name) : \(mode.shortcut?.label ?? "aucune touche")")
            return 0
        }
        if let path = value("--cleanup-model") { CleanupModel.overridePath = path }
        if let path = value("--cleanuptest") { return await cleanupTest(path) }
        if let path = value("--guardtest") { return guardTest(path) }
        if let textsPath = value("--llmtest") {
            return await llmTest(textsPath, llms: value("--llm") ?? "", settings: settings,
                                 tone: value("--tone").flatMap(AutoTone.init(rawValue:)),
                                 template: value("--template"), value: value)
        }
        guard let path = value("--selftest") else { return 2 }
        let modelID = value("--model") ?? settings.selectedModelID
        guard let model = ModelCatalog.model(modelID) else {
            print("Modèle inconnu : \(modelID)"); return 2
        }

        do {
            let samples = try AudioFile.load(URL(fileURLWithPath: path))
            print("Audio : \(String(format: "%.1f", Double(samples.count) / AudioRecorder.sampleRate)) s")

            let manager = ModelManager.shared
            if model.needsDownload, !manager.isReady(model) {
                print("Téléchargement de \(model.name)…")
                manager.download(model)
                while true {
                    switch manager.status(model) {
                    case .installed: break
                    case .failed(let m): print("Échec : \(m)"); return 1
                    default: try await Task.sleep(nanoseconds: 500_000_000); continue
                    }
                    break
                }
            }
            var t = Date()
            let engine = try await manager.engine(for: model)
            print("Chargement : \(String(format: "%.2f", Date().timeIntervalSince(t))) s")
            t = Date()
            let language = settings.language == "auto" || model.isEnglishOnly ? nil : settings.language
            let raw = try await engine.transcribe(samples, language: language, vocabulary: settings.dictionary)
            print("[\(model.name)] \(String(format: "%.2f", Date().timeIntervalSince(t))) s")
            print("Brut : \(TextProcessing.apply(raw, replacements: settings.replacements))")
            if await ensureCleanupModel(), await CleanupModel.shared.waitUntilReady() {
                let r = await CleanupModel.shared.clean(TextProcessing.apply(raw, replacements: []))
                print("[Cleanup 2] \(String(format: "%.2f", r.seconds)) s\(r.usedModel ? "" : " · repli : \(r.fallbackReason)")")
                print("Nettoyé : \(r.text)")
            }

            if let llmID = value("--llm"), let llm = LocalLLM.model(llmID) {
                let ai = PostProcessor.shared
                if !ai.installed.contains(llm.id) {
                    print("Téléchargement de \(llm.name) (\(llm.sizeLabel))…")
                    ai.download(llm)
                    while !ai.installed.contains(llm.id) {
                        if ai.downloadProgress[llm.id] == nil, let e = ai.lastError { print("Échec : \(e)"); return 1 }
                        try await Task.sleep(nanoseconds: 500_000_000)
                    }
                }
                settings.aiBackend = .embedded
                settings.aiLocalModelID = llm.id
                let modeName = value("--mode")
                let mode = modeName.flatMap { name in
                    ModeStore.shared.mode(named: name) ?? ModeTemplates.all.first { $0.name == name }
                } ?? Mode.main()
                t = Date()
                var out = try await ai.process(raw, mode: mode, context: DictationContext(), settings: settings)
                if let target = mode.translateTo {
                    out = try await Translator.shared.translate(out, from: settings.language, to: target)
                }
                print("[\(llm.name) · \(mode.name)] \(String(format: "%.2f", Date().timeIntervalSince(t))) s")
                print("IA : \(out)")
            }
            return 0
        } catch {
            print("Erreur : \(error.localizedDescription)")
            return 1
        }
    }
}

extension SelfTest {
    /// Compare des LLM sur des transcriptions brutes (une par ligne) :
    ///   Murmure --llmtest textes.txt --llm qwen2.5-1.5b,gemma-3-1b
    ///   Murmure --llmtest textes.txt --llm qwen2.5-1.5b --template E-mail   (consignes d'un modèle de mode)
    static func llmTest(_ path: String, llms: String, settings: Settings, tone: AutoTone? = nil,
                        template: String? = nil, value: (String) -> String? = { _ in nil }) async -> Int32 {
        // Sortie non mise en tampon : un test interrompu garde les lignes déjà produites.
        setvbuf(stdout, nil, _IONBF, 0)
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { print("Fichier illisible"); return 2 }
        let texts = content.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        let ai = PostProcessor.shared
        var mode = Mode.main()
        if let template {
            guard let t = ModeTemplates.all.first(where: { $0.name.caseInsensitiveCompare(template) == .orderedSame }) else {
                print("Modèle de mode inconnu : \(template)"); return 2
            }
            mode = t
        }
        if let file = value("--instructions"), let text = try? String(contentsOfFile: file, encoding: .utf8) {
            mode.instructions = text
        }
        for id in llms.split(separator: ",").map(String.init) {
            guard let llm = LocalLLM.model(id) else { print("LLM inconnu : \(id)"); continue }
            if !ai.installed.contains(llm.id) {
                print("Téléchargement de \(llm.name)…")
                ai.download(llm)
                while !ai.installed.contains(llm.id) {
                    if ai.downloadProgress[llm.id] == nil, let e = ai.lastError { print("Échec : \(e)"); return 1 }
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
            }
            settings.aiBackend = .embedded
            settings.aiLocalModelID = llm.id
            print("\n===== \(llm.name)\(tone.map { " · ton \($0.rawValue)" } ?? "") =====")
            for (i, text) in texts.enumerated() {
                let t = Date()
                do {
                    let out = try await ai.process(TextProcessing.removeFillers(text), mode: mode, context: DictationContext(),
                                                   settings: settings, tone: tone)
                    print("#\(i + 1) [\(String(format: "%.2f", Date().timeIntervalSince(t))) s] \(out)")
                } catch {
                    print("#\(i + 1) ERREUR \(error.localizedDescription)")
                }
            }
        }
        return 0
    }
}

extension SelfTest {
    /// Rejoue la réparation et le garde-fou de Cleanup 2 sur des sorties déjà calculées ({"raw", "out"} par
    /// ligne) : une ligne « décision<TAB>texte réparé » par entrée (comparaison avec evaluate.py).
    static func guardTest(_ path: String) -> Int32 {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return 2 }
        for line in content.split(separator: "\n") {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let raw = obj["raw"] as? String, let out = obj["out"] as? String else { continue }
            let repaired = CleanupModel.repair(output: out, input: raw)
            let problem = CleanupModel.guardProblem(output: repaired, input: raw)
            print("\(problem == nil ? "ok" : "rejet")\t\(repaired)")
        }
        return 0
    }

    /// Télécharge Cleanup 2 si besoin. Faux si le téléchargement échoue.
    static func ensureCleanupModel() async -> Bool {
        let cleanup = CleanupModel.shared
        if cleanup.isInstalled { return true }
        let ai = PostProcessor.shared
        print("Téléchargement de \(LocalLLM.cleanup.name)…")
        ai.download(.cleanup)
        while !cleanup.isInstalled {
            if ai.downloadProgress[LocalLLM.cleanup.id] == nil, let e = ai.lastError { print("Échec : \(e)"); return false }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        return true
    }

    /// Banc de Murmure Cleanup 2 : une dictée brute par ligne (.txt), ou des objets {"raw", "ref"} (.jsonl).
    /// Affiche le résultat, le temps et les replis, puis la latence médiane et le taux de replis.
    ///   Murmure --cleanuptest Tests/cleanup-bench/eval.jsonl
    static func cleanupTest(_ path: String) async -> Int32 {
        setvbuf(stdout, nil, _IONBF, 0)
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { print("Fichier illisible"); return 2 }
        var cases: [(raw: String, ref: String?)] = []
        for line in content.split(separator: "\n").map(String.init) where !line.isEmpty {
            if path.hasSuffix(".jsonl"), let data = line.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let raw = obj["raw"] as? String {
                cases.append((raw, obj["ref"] as? String))
            } else {
                cases.append((line, nil))
            }
        }
        guard await ensureCleanupModel() else { return 1 }
        let cleanup = CleanupModel.shared
        var t = Date()
        guard await cleanup.waitUntilReady() else { print("Chargement impossible"); return 1 }
        _ = await cleanup.clean("ok")
        print("Chargement : \(String(format: "%.2f", Date().timeIntervalSince(t))) s")
        var times: [Double] = [], fallbacks = 0, exact = 0, rulesExact = 0
        for (i, c) in cases.enumerated() {
            t = Date()
            let r = await cleanup.clean(c.raw)
            times.append(Date().timeIntervalSince(t))
            if !r.usedModel { fallbacks += 1 }
            print("#\(i + 1) [\(String(format: "%.3f", times.last!)) s]\(r.usedModel ? "" : " [repli : \(r.fallbackReason)]") \(r.text)")
            if let ref = c.ref {
                if r.text == ref { exact += 1 }
                if TextProcessing.removeFillers(c.raw) == ref { rulesExact += 1 }
                if r.text != ref { print("   attendu : \(ref)") }
            }
        }
        let sorted = times.sorted()
        print(String(format: "\n%d dictées · médiane %.3f s · p90 %.3f s · max %.3f s · replis %d",
                     cases.count, sorted[sorted.count / 2], sorted[Int(Double(sorted.count) * 0.9)], sorted.last!, fallbacks))
        if cases.contains(where: { $0.ref != nil }) {
            print("Identiques à la référence : Cleanup 2 \(exact)/\(cases.count), règles \(rulesExact)/\(cases.count)")
        }
        return 0
    }
}

extension SelfTest {
    /// Demande un jeton d'essai au serveur de production pour un Mac fictif et vérifie sa signature.
    static func licenseTest() async -> Int32 {
        let device = (0..<32).map { _ in String("0123456789abcdef".randomElement()!) }.joined()
        var req = URLRequest(url: LicenseManager.server.appendingPathComponent("/v1/device"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["device_id": device, "app_version": "selftest"])
        guard let result = try? await URLSession.shared.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: result.0) as? [String: Any],
              let payload = json["token"] as? String, let signature = json["signature"] as? String else {
            print("Licence : serveur injoignable (\(LicenseManager.server))"); return 1
        }
        guard let token = LicenseManager.verify(payload: payload, signature: signature), token.device == device else {
            print("Licence : signature ou contenu invalide"); return 1
        }
        let days = Int(((token.trialEndsAt ?? Date()).timeIntervalSinceNow / 86_400).rounded())
        print("Licence OK : plan \(token.plan), essai \(days) jours, serveur \(LicenseManager.server)")
        return days == LicenseManager.trialDays ? 0 : 1
    }
}

enum AudioFile {
    /// Lit un fichier audio et le convertit en Float32 mono 16 kHz.
    static func load(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioRecorder.sampleRate,
                                   channels: 1, interleaved: false)!
        guard let converter = AVAudioConverter(from: file.processingFormat, to: target),
              let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))
        else { throw MurmureError.emptyAudio }
        try file.read(into: input)
        let capacity = AVAudioFrameCount(Double(input.frameLength) * AudioRecorder.sampleRate / file.processingFormat.sampleRate) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { throw MurmureError.emptyAudio }
        var done = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if done { status.pointee = .endOfStream; return nil }
            done = true
            status.pointee = .haveData
            return input
        }
        if let error { throw error }
        return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    }
}
