import Foundation

/// Transcription par API, avec la clé de l'utilisateur. Murmure n'est jamais intermédiaire.
final class CloudEngine: TranscriptionEngine {
    let provider: CloudProvider
    let model: String

    init(provider: CloudProvider, model: String) {
        self.provider = provider
        self.model = model
    }

    /// Pour le serveur compatible OpenAI : URL de base et modèle choisis par l'utilisateur.
    static var customBaseURL: String {
        get { UserDefaults.standard.string(forKey: "customSTTBaseURL") ?? "http://localhost:8000/v1" }
        set { UserDefaults.standard.set(newValue, forKey: "customSTTBaseURL") }
    }
    static var customModel: String {
        get { UserDefaults.standard.string(forKey: "customSTTModel") ?? "whisper-1" }
        set { UserDefaults.standard.set(newValue, forKey: "customSTTModel") }
    }

    func transcribe(_ samples: [Float], language: String?, vocabulary: [String]) async throws -> String {
        let key = Keychain.apiKey(provider)
        if provider != .custom, key == nil { throw MurmureError.missingAPIKey(provider.name) }
        let wav = WAV.encode(samples, sampleRate: Int(AudioRecorder.sampleRate))

        switch provider {
        case .openAI:
            return try await openAICompatible(base: "https://api.openai.com/v1", key: key, model: model,
                                              wav: wav, language: language, vocabulary: vocabulary,
                                              newStyle: model == "gpt-transcribe")
        case .groq:
            return try await openAICompatible(base: "https://api.groq.com/openai/v1", key: key, model: model,
                                              wav: wav, language: language, vocabulary: vocabulary)
        case .mistral:
            return try await openAICompatible(base: "https://api.mistral.ai/v1", key: key, model: model,
                                              wav: wav, language: language, vocabulary: [])
        case .custom:
            return try await openAICompatible(base: Self.customBaseURL, key: key, model: Self.customModel,
                                              wav: wav, language: language, vocabulary: vocabulary)
        case .xAI:
            var form = Multipart()
            form.add("model", model)
            form.addFile("file", "audio.wav", "audio/wav", wav)
            let json = try await send(url: "https://api.x.ai/v1/stt", form: form,
                                      headers: ["Authorization": "Bearer \(key!)"])
            return json["text"] as? String ?? ""
        case .elevenLabs:
            var form = Multipart()
            form.add("model_id", model)
            if let language { form.add("language_code", language) }
            for term in vocabulary.prefix(100) { form.add("keyterms", term) }
            form.addFile("file", "audio.wav", "audio/wav", wav)
            let json = try await send(url: "https://api.elevenlabs.io/v1/speech-to-text", form: form,
                                      headers: ["xi-api-key": key!])
            return json["text"] as? String ?? ""
        case .cartesia:
            var form = Multipart()
            form.add("model", model)
            form.add("language", language ?? "en")
            form.addFile("file", "audio.wav", "audio/wav", wav)
            let json = try await send(url: "https://api.cartesia.ai/stt", form: form,
                                      headers: ["Authorization": "Bearer \(key!)", "Cartesia-Version": "2026-08-14"])
            return json["text"] as? String ?? ""
        case .deepgram:
            return try await deepgram(key: key!, wav: wav, language: language, vocabulary: vocabulary)
        case .assemblyAI:
            return try await assemblyAI(key: key!, wav: wav, language: language, vocabulary: vocabulary)
        }
    }

    // MARK: Fournisseurs

    private func openAICompatible(base: String, key: String?, model: String, wav: Data, language: String?,
                                  vocabulary: [String], newStyle: Bool = false) async throws -> String {
        var form = Multipart()
        form.add("model", model)
        form.add("response_format", "json")
        if let language {
            form.add(newStyle ? "languages[]" : "language", language)
        }
        if !vocabulary.isEmpty {
            if newStyle {
                for word in vocabulary.prefix(100) { form.add("keywords[]", word) }
            } else {
                form.add("prompt", vocabulary.joined(separator: ", "))
            }
        }
        form.addFile("file", "audio.wav", "audio/wav", wav)
        var headers: [String: String] = [:]
        if let key { headers["Authorization"] = "Bearer \(key)" }
        let json = try await send(url: base.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/audio/transcriptions",
                                  form: form, headers: headers)
        return json["text"] as? String ?? ""
    }

    private func deepgram(key: String, wav: Data, language: String?, vocabulary: [String]) async throws -> String {
        var comps = URLComponents(string: "https://api.deepgram.com/v1/listen")!
        var items = [URLQueryItem(name: "model", value: model), URLQueryItem(name: "smart_format", value: "true")]
        if let language { items.append(URLQueryItem(name: "language", value: language)) } else {
            items.append(URLQueryItem(name: "detect_language", value: "true"))
        }
        items += vocabulary.prefix(50).map { URLQueryItem(name: "keyterm", value: $0) }
        comps.queryItems = items
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "POST"
        req.setValue("Token \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        req.httpBody = wav
        let json = try await Self.json(for: req)
        let results = json["results"] as? [String: Any]
        let channel = (results?["channels"] as? [[String: Any]])?.first
        let alt = (channel?["alternatives"] as? [[String: Any]])?.first
        return alt?["transcript"] as? String ?? ""
    }

    private func assemblyAI(key: String, wav: Data, language: String?, vocabulary: [String]) async throws -> String {
        var upload = URLRequest(url: URL(string: "https://api.assemblyai.com/v2/upload")!)
        upload.httpMethod = "POST"
        upload.setValue(key, forHTTPHeaderField: "authorization")
        upload.httpBody = wav
        guard let audioURL = try await Self.json(for: upload)["upload_url"] as? String else {
            throw MurmureError.http(0, "AssemblyAI n'a pas renvoyé d'URL d'envoi.")
        }

        var body: [String: Any] = ["audio_url": audioURL, "speech_models": [model]]
        if let language { body["language_code"] = language } else { body["language_detection"] = true }
        if !vocabulary.isEmpty { body["keyterms_prompt"] = Array(vocabulary.prefix(200)) }
        var create = URLRequest(url: URL(string: "https://api.assemblyai.com/v2/transcript")!)
        create.httpMethod = "POST"
        create.setValue(key, forHTTPHeaderField: "authorization")
        create.setValue("application/json", forHTTPHeaderField: "Content-Type")
        create.httpBody = try JSONSerialization.data(withJSONObject: body)
        guard let id = try await Self.json(for: create)["id"] as? String else {
            throw MurmureError.http(0, "AssemblyAI n'a pas créé la transcription.")
        }

        var poll = URLRequest(url: URL(string: "https://api.assemblyai.com/v2/transcript/\(id)")!)
        poll.setValue(key, forHTTPHeaderField: "authorization")
        for _ in 0..<120 {
            let json = try await Self.json(for: poll)
            switch json["status"] as? String {
            case "completed": return json["text"] as? String ?? ""
            case "error": throw MurmureError.http(0, json["error"] as? String ?? "échec")
            default: try await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        throw MurmureError.http(0, "AssemblyAI : délai dépassé.")
    }

    // MARK: HTTP

    private func send(url: String, form: Multipart, headers: [String: String]) async throws -> [String: Any] {
        guard let u = URL(string: url) else { throw MurmureError.unsupported("URL invalide : \(url)") }
        var req = URLRequest(url: u)
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.setValue("multipart/form-data; boundary=\(form.boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = form.finalized()
        return try await Self.json(for: req)
    }

    static func json(for request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw MurmureError.http(code, String(data: data, encoding: .utf8) ?? "")
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
}

struct Multipart {
    let boundary = "murmure-\(UUID().uuidString)"
    private var body = Data()

    mutating func add(_ name: String, _ value: String) {
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
    }

    mutating func addFile(_ name: String, _ filename: String, _ mime: String, _ data: Data) {
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\nContent-Type: \(mime)\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n".data(using: .utf8)!)
    }

    func finalized() -> Data {
        var d = body
        d.append("--\(boundary)--\r\n".data(using: .utf8)!)
        return d
    }
}

enum WAV {
    /// Encode des échantillons Float32 mono en WAV PCM 16 bits.
    static func encode(_ samples: [Float], sampleRate: Int) -> Data {
        var data = Data()
        let byteRate = sampleRate * 2
        let dataSize = samples.count * 2
        func u32(_ v: Int) { var x = UInt32(v).littleEndian; data.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: Int) { var x = UInt16(v).littleEndian; data.append(Data(bytes: &x, count: 2)) }
        data.append("RIFF".data(using: .ascii)!); u32(36 + dataSize)
        data.append("WAVE".data(using: .ascii)!)
        data.append("fmt ".data(using: .ascii)!); u32(16); u16(1); u16(1); u32(sampleRate); u32(byteRate); u16(2); u16(16)
        data.append("data".data(using: .ascii)!); u32(dataSize)
        var pcm = [Int16](repeating: 0, count: samples.count)
        for i in samples.indices { pcm[i] = Int16(max(-1, min(1, samples[i])) * Float(Int16.max)) }
        pcm.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }
}
