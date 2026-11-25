import Foundation

enum CloudProvider: String, CaseIterable, Codable, Identifiable {
    case openAI, groq, elevenLabs, deepgram, xAI, assemblyAI, cartesia, mistral, custom

    var id: String { rawValue }

    var name: String {
        switch self {
        case .openAI: return "OpenAI"
        case .groq: return "Groq"
        case .elevenLabs: return "ElevenLabs"
        case .deepgram: return "Deepgram"
        case .xAI: return "xAI"
        case .assemblyAI: return "AssemblyAI"
        case .cartesia: return "Cartesia"
        case .mistral: return "Mistral AI"
        case .custom: return "Serveur compatible OpenAI"
        }
    }

    var keyURL: URL? {
        switch self {
        case .openAI: return URL(string: "https://platform.openai.com/api-keys")
        case .groq: return URL(string: "https://console.groq.com/keys")
        case .elevenLabs: return URL(string: "https://elevenlabs.io/app/settings/api-keys")
        case .deepgram: return URL(string: "https://console.deepgram.com")
        case .xAI: return URL(string: "https://console.x.ai")
        case .assemblyAI: return URL(string: "https://www.assemblyai.com/dashboard")
        case .cartesia: return URL(string: "https://play.cartesia.ai/keys")
        case .mistral: return URL(string: "https://console.mistral.ai/api-keys")
        case .custom: return nil
        }
    }
}

enum ModelKind: Hashable {
    case whisper(variant: String)
    case parakeet(version: String)
    case parakeetUnified
    case nemotronLite
    case appleSpeech
    case cloud(provider: CloudProvider, model: String)
}

struct SpeechModel: Identifiable, Hashable {
    let id: String
    let name: String
    let kind: ModelKind
    /// Taille approximative du téléchargement, en Mo (0 = rien à télécharger).
    let sizeMB: Int
    let languages: String
    /// Notes publiées par Spokenly (1 à 5), pour comparer.
    let accuracy: Double
    let speed: Double
    let note: String?
    /// Système minimum requis, si plus récent que macOS 14.
    let minMacOS: Int?

    init(_ id: String, _ name: String, _ kind: ModelKind, size: Int = 0, languages: String,
         accuracy: Double, speed: Double, note: String? = nil, minMacOS: Int? = nil) {
        self.id = id; self.name = name; self.kind = kind; self.sizeMB = size
        self.languages = languages; self.accuracy = accuracy; self.speed = speed
        self.note = note; self.minMacOS = minMacOS
    }

    var isLocal: Bool {
        if case .cloud = kind { return false }
        return true
    }

    var needsDownload: Bool {
        switch kind {
        case .cloud, .appleSpeech: return false
        default: return true
        }
    }

    var provider: CloudProvider? {
        if case .cloud(let p, _) = kind { return p }
        return nil
    }

    var isEnglishOnly: Bool { languages == "Anglais" }

    var sizeLabel: String {
        guard sizeMB > 0 else { return "" }
        return sizeMB >= 1000 ? String(format: "%.1f Go", Double(sizeMB) / 1000) : "\(sizeMB) Mo"
    }

    var isSupportedOnThisMac: Bool {
        guard let min = minMacOS else { return true }
        return ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= min
    }
}

enum ModelCatalog {
    static let local: [SpeechModel] = [
        SpeechModel("parakeet-ultra", "Parakeet Ultra", .parakeet(version: "ultra"), size: 632,
                    languages: "25 langues", accuracy: 4.5, speed: 4.5),
        SpeechModel("parakeet-v3", "Parakeet TDT 0.6B V3", .parakeet(version: "v3"), size: 496,
                    languages: "25 langues", accuracy: 4.0, speed: 4.5, note: "Recommandé pour le français"),
        SpeechModel("parakeet-redux", "Parakeet Redux", .parakeet(version: "redux"), size: 220,
                    languages: "25 langues", accuracy: 4.0, speed: 4.5),
        SpeechModel("parakeet-v2", "Parakeet TDT 0.6B V2", .parakeet(version: "v2"), size: 496,
                    languages: "Anglais", accuracy: 4.5, speed: 4.5),
        SpeechModel("parakeet-unified", "Parakeet Unified 0.6B", .parakeetUnified, size: 1200,
                    languages: "Anglais", accuracy: 4.5, speed: 4.5),
        SpeechModel("bark-3", "Bark 3.0", .parakeet(version: "bark3"), size: 436,
                    languages: "Anglais", accuracy: 4.5, speed: 4.5, minMacOS: 15),
        SpeechModel("phonon-2", "Phonon-2", .parakeet(version: "phonon2"), size: 358,
                    languages: "Anglais", accuracy: 4.0, speed: 4.5, minMacOS: 15),
        SpeechModel("nemotron-lite", "Nemotron Transcribe Lite", .nemotronLite, size: 1300,
                    languages: "Multilingue", accuracy: 4.0, speed: 4.5, minMacOS: 15),
        SpeechModel("whisper-large-v3", "Whisper Large v3", .whisper(variant: "openai_whisper-large-v3"), size: 2900,
                    languages: "99 langues", accuracy: 3.5, speed: 2.5),
        SpeechModel("whisper-large-v3-turbo", "Whisper Large v3 Turbo",
                    .whisper(variant: "openai_whisper-large-v3-v20240930"), size: 1500,
                    languages: "99 langues", accuracy: 3.0, speed: 3.0),
        SpeechModel("whisper-large-v3-turbo-q", "Whisper Large v3 Turbo (quantifié)",
                    .whisper(variant: "openai_whisper-large-v3-v20240930_547MB"), size: 547,
                    languages: "99 langues", accuracy: 2.5, speed: 3.5),
        SpeechModel("whisper-large-v2", "Whisper Large v2", .whisper(variant: "openai_whisper-large-v2"), size: 2900,
                    languages: "99 langues", accuracy: 3.0, speed: 3.5),
        SpeechModel("distil-whisper-large-v3", "Distil-Whisper Large v3",
                    .whisper(variant: "distil-whisper_distil-large-v3"), size: 1500,
                    languages: "Anglais", accuracy: 3.5, speed: 3.0),
        SpeechModel("whisper-small", "Whisper Small", .whisper(variant: "openai_whisper-small"), size: 465,
                    languages: "99 langues", accuracy: 3.0, speed: 4.0),
        SpeechModel("whisper-base", "Whisper Base", .whisper(variant: "openai_whisper-base"), size: 141,
                    languages: "99 langues", accuracy: 2.0, speed: 4.5),
        SpeechModel("whisper-tiny", "Whisper Tiny", .whisper(variant: "openai_whisper-tiny"), size: 75,
                    languages: "99 langues", accuracy: 1.0, speed: 5.0),
        SpeechModel("whisper-tiny-en", "Whisper Tiny (anglais)", .whisper(variant: "openai_whisper-tiny.en"), size: 75,
                    languages: "Anglais", accuracy: 1.0, speed: 5.0),
        SpeechModel("apple-speech", "Apple Speech Recognition", .appleSpeech,
                    languages: "Langues du système", accuracy: 3.0, speed: 4.5,
                    note: "Moteur intégré à macOS, rien à télécharger"),
    ]

    static let cloud: [SpeechModel] = [
        SpeechModel("elevenlabs-scribe", "ElevenLabs Scribe", .cloud(provider: .elevenLabs, model: "scribe_v2"),
                    languages: "99 langues", accuracy: 5.0, speed: 4.0),
        SpeechModel("xai-grok-stt", "Grok STT", .cloud(provider: .xAI, model: "grok-voice-transcribe-2.0"),
                    languages: "38 langues", accuracy: 5.0, speed: 5.0),
        SpeechModel("assemblyai-stt", "AssemblyAI STT-3.7", .cloud(provider: .assemblyAI, model: "assemblyai-stt-3-7"),
                    languages: "Multilingue", accuracy: 5.0, speed: 1.5),
        SpeechModel("openai-gpt-transcribe", "GPT Transcribe", .cloud(provider: .openAI, model: "gpt-transcribe"),
                    languages: "Multilingue", accuracy: 4.5, speed: 3.5),
        SpeechModel("openai-gpt-4o-mini", "GPT-4o mini Transcribe",
                    .cloud(provider: .openAI, model: "gpt-4o-mini-transcribe"),
                    languages: "Multilingue", accuracy: 4.0, speed: 4.0, note: "Arrêt annoncé par OpenAI le 26 février 2027"),
        SpeechModel("deepgram-nova-3", "Nova-3", .cloud(provider: .deepgram, model: "nova-3"),
                    languages: "Multilingue", accuracy: 3.5, speed: 5.0),
        SpeechModel("groq-whisper-large-v3", "Whisper Large v3 (Groq)",
                    .cloud(provider: .groq, model: "whisper-large-v3"),
                    languages: "99 langues", accuracy: 3.5, speed: 4.5),
        SpeechModel("groq-whisper-turbo", "Whisper v3 Turbo (Groq)",
                    .cloud(provider: .groq, model: "whisper-large-v3-turbo"),
                    languages: "99 langues", accuracy: 3.0, speed: 4.5),
        SpeechModel("mistral-voxtral", "Voxtral Mini Transcribe",
                    .cloud(provider: .mistral, model: "voxtral-mini-latest"),
                    languages: "Multilingue", accuracy: 4.5, speed: 4.0),
        SpeechModel("cartesia-ink", "Cartesia Ink Whisper", .cloud(provider: .cartesia, model: "ink-whisper"),
                    languages: "Multilingue", accuracy: 3.0, speed: 5.0),
        SpeechModel("custom-openai", "Serveur compatible OpenAI", .cloud(provider: .custom, model: ""),
                    languages: "Selon le serveur", accuracy: 0, speed: 0,
                    note: "Par exemple un serveur Whisper local, ou un fournisseur non listé"),
    ]

    static var all: [SpeechModel] { local + cloud }

    static func model(_ id: String) -> SpeechModel? { all.first { $0.id == id } }
}

/// LLM locaux pour le post-traitement (fichiers GGUF, exécutés par llama.cpp).
struct LocalLLM: Identifiable, Hashable {
    let id: String
    let name: String
    let repo: String
    let file: String
    let sizeBytes: Int64
    let note: String

    var url: URL { URL(string: "https://huggingface.co/\(repo)/resolve/main/\(file)")! }
    var sizeLabel: String { String(format: "%.1f Go", Double(sizeBytes) / 1_000_000_000) }

    static let all: [LocalLLM] = [
        LocalLLM(id: "gemma-3-1b", name: "Gemma 3 1B", repo: "unsloth/gemma-3-1b-it-GGUF",
                 file: "gemma-3-1b-it-Q4_K_M.gguf", sizeBytes: 806_058_272,
                 note: "Le plus rapide. Correct pour la ponctuation et les hésitations."),
        LocalLLM(id: "qwen2.5-1.5b", name: "Qwen 2.5 1.5B", repo: "Qwen/Qwen2.5-1.5B-Instruct-GGUF",
                 file: "qwen2.5-1.5b-instruct-q4_k_m.gguf", sizeBytes: 1_117_320_736,
                 note: "Bon compromis vitesse et qualité. Recommandé."),
        LocalLLM(id: "qwen2.5-3b", name: "Qwen 2.5 3B", repo: "Qwen/Qwen2.5-3B-Instruct-GGUF",
                 file: "qwen2.5-3b-instruct-q4_k_m.gguf", sizeBytes: 2_104_932_768,
                 note: "Meilleures reformulations, un peu plus lent."),
        LocalLLM(id: "gemma-3-4b", name: "Gemma 3 4B", repo: "unsloth/gemma-3-4b-it-GGUF",
                 file: "gemma-3-4b-it-Q4_K_M.gguf", sizeBytes: 2_489_894_016,
                 note: "Très bon en français. Pour les modes e-mail et traduction."),
        LocalLLM(id: "qwen3-4b", name: "Qwen3 4B Instruct", repo: "unsloth/Qwen3-4B-Instruct-2507-GGUF",
                 file: "Qwen3-4B-Instruct-2507-Q4_K_M.gguf", sizeBytes: 2_497_281_120,
                 note: "Le plus capable de la liste. Demande 16 Go de mémoire pour rester fluide."),
    ]

    static func model(_ id: String) -> LocalLLM? { all.first { $0.id == id } }
}
