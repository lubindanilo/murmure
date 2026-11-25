import Foundation
import SwiftUI

/// Touche utilisée pour déclencher la dictée.
enum TriggerKey: String, CaseIterable, Codable, Identifiable {
    case fn, rightOption, rightCommand, rightControl, rightShift, leftOption

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fn: return "Fn (globe)"
        case .rightOption: return "⌥ droite"
        case .rightCommand: return "⌘ droite"
        case .rightControl: return "⌃ droite"
        case .rightShift: return "⇧ droite"
        case .leftOption: return "⌥ gauche"
        }
    }

    /// Code matériel de la touche (événements flagsChanged).
    var keyCode: UInt16 {
        switch self {
        case .fn: return 63
        case .rightOption: return 61
        case .rightCommand: return 54
        case .rightControl: return 62
        case .rightShift: return 60
        case .leftOption: return 58
        }
    }

    var flag: NSEvent.ModifierFlags {
        switch self {
        case .fn: return .function
        case .rightOption, .leftOption: return .option
        case .rightCommand: return .command
        case .rightControl: return .control
        case .rightShift: return .shift
        }
    }
}

enum TriggerMode: String, CaseIterable, Codable, Identifiable {
    case hold, toggle
    var id: String { rawValue }
    var label: String {
        switch self {
        case .hold: return "Maintenir pour parler"
        case .toggle: return "Appuyer pour démarrer, appuyer pour arrêter"
        }
    }
}

enum OutputMode: String, CaseIterable, Codable, Identifiable {
    case paste, pasteAndSend, copy, historyOnly
    var id: String { rawValue }
    var label: String {
        switch self {
        case .paste: return "Coller au curseur"
        case .pasteAndSend: return "Coller puis Entrée"
        case .copy: return "Copier dans le presse-papiers"
        case .historyOnly: return "Historique seulement"
        }
    }
}

struct WordReplacement: Codable, Identifiable, Hashable {
    var id = UUID()
    var from: String
    var to: String
    var caseSensitive = false
}

enum AIBackend: String, CaseIterable, Codable, Identifiable {
    case embedded, ollama, lmStudio
    var id: String { rawValue }
    var label: String {
        switch self {
        case .embedded: return "Intégré (llama.cpp)"
        case .ollama: return "Ollama"
        case .lmStudio: return "LM Studio"
        }
    }
    var defaultBaseURL: String {
        switch self {
        case .embedded: return ""
        case .ollama: return "http://localhost:11434/v1"
        case .lmStudio: return "http://localhost:1234/v1"
        }
    }
}

/// Réglages persistés dans UserDefaults (les clés API vont dans le trousseau).
final class Settings: ObservableObject {
    static let shared = Settings()
    private let defaults = UserDefaults.standard

    @Published var triggerKey: TriggerKey { didSet { save(triggerKey.rawValue, "triggerKey") } }
    @Published var triggerMode: TriggerMode { didSet { save(triggerMode.rawValue, "triggerMode") } }
        /// Modèle de transcription unique : Parakeet Ultra, installé au premier lancement.
    let selectedModelID: String
    /// Code ISO de la langue, ou "auto".
    @Published var language: String { didSet { save(language, "language") } }
    @Published var playSounds: Bool { didSet { save(playSounds, "playSounds") } }
    @Published var restoreClipboard: Bool { didSet { save(restoreClipboard, "restoreClipboard") } }
    @Published var historyLimit: Int { didSet { save(historyLimit, "historyLimit") } }

    @Published var dictionary: [String] { didSet { saveCodable(dictionary, "dictionary") } }
    @Published var replacements: [WordReplacement] { didSet { saveCodable(replacements, "replacements") } }

    @Published var aiEnabled: Bool { didSet { save(aiEnabled, "aiEnabled") } }
    @Published var aiBackend: AIBackend { didSet { save(aiBackend.rawValue, "aiBackend") } }
    @Published var aiLocalModelID: String { didSet { save(aiLocalModelID, "aiLocalModelID") } }
    @Published var aiServerModel: String { didSet { save(aiServerModel, "aiServerModel") } }
    @Published var aiServerURL: String { didSet { save(aiServerURL, "aiServerURL") } }

    @Published var hasCompletedOnboarding: Bool { didSet { save(hasCompletedOnboarding, "hasCompletedOnboarding") } }

    private init() {
        let d = UserDefaults.standard
        triggerKey = TriggerKey(rawValue: d.string(forKey: "triggerKey") ?? "") ?? .rightCommand
        triggerMode = TriggerMode(rawValue: d.string(forKey: "triggerMode") ?? "") ?? .hold
        selectedModelID = "parakeet-ultra"
        language = d.string(forKey: "language") ?? "fr"
        playSounds = d.object(forKey: "playSounds") as? Bool ?? true
        restoreClipboard = d.object(forKey: "restoreClipboard") as? Bool ?? true
        historyLimit = d.object(forKey: "historyLimit") as? Int ?? 500
        dictionary = Self.loadCodable([String].self, "dictionary", d) ?? []
        replacements = Self.loadCodable([WordReplacement].self, "replacements", d) ?? []
        aiEnabled = d.object(forKey: "aiEnabled") as? Bool ?? true
        aiBackend = AIBackend(rawValue: d.string(forKey: "aiBackend") ?? "") ?? .embedded
        aiLocalModelID = d.string(forKey: "aiLocalModelID") ?? "qwen2.5-1.5b"
        aiServerModel = d.string(forKey: "aiServerModel") ?? ""
        aiServerURL = d.string(forKey: "aiServerURL") ?? ""
        hasCompletedOnboarding = d.bool(forKey: "hasCompletedOnboarding")
    }

    var effectiveServerURL: String {
        aiServerURL.isEmpty ? aiBackend.defaultBaseURL : aiServerURL
    }

    private func save(_ value: Any, _ key: String) { defaults.set(value, forKey: key) }
    private func saveCodable<T: Encodable>(_ value: T, _ key: String) {
        defaults.set(try? JSONEncoder().encode(value), forKey: key)
    }
    private static func loadCodable<T: Decodable>(_ type: T.Type, _ key: String, _ d: UserDefaults) -> T? {
        guard let data = d.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

/// Langues proposées dans les réglages.
enum Languages {
    static let all: [(code: String, name: String)] = [
        ("auto", "Détection automatique"), ("fr", "Français"), ("en", "Anglais"), ("es", "Espagnol"),
        ("de", "Allemand"), ("it", "Italien"), ("pt", "Portugais"), ("nl", "Néerlandais"),
        ("pl", "Polonais"), ("ru", "Russe"), ("uk", "Ukrainien"), ("ja", "Japonais"),
        ("zh", "Chinois"), ("ko", "Coréen"), ("ar", "Arabe"), ("tr", "Turc"), ("sv", "Suédois"),
    ]
    static func name(_ code: String) -> String { all.first { $0.code == code }?.name ?? code }
}
