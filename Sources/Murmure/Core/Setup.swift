import Combine
import Foundation

/// Installation au premier lancement : Parakeet Ultra pour la transcription,
/// et le petit LLM de nettoyage. Rien à choisir pour l'utilisateur.
@MainActor
final class Setup: ObservableObject {
    static let shared = Setup()

    /// LLM installé par défaut pour le nettoyage et les modes.
    static let defaultLLM = "qwen2.5-1.5b"

    private let models = ModelManager.shared
    private let ai = PostProcessor.shared
    private let settings = Settings.shared
    private var bag = Set<AnyCancellable>()
    private var started = false

    struct Item: Identifiable {
        let id: String
        let title: String
        let detail: String
        let progress: Double?   // nil = terminé
        let error: String?
    }

    @Published private(set) var items: [Item] = []

    var speechModel: SpeechModel { ModelCatalog.model(settings.selectedModelID) ?? ModelCatalog.local[0] }

    var isComplete: Bool { items.allSatisfy { $0.progress == nil && $0.error == nil } }

    func isReady(_ model: SpeechModel) -> Bool { models.isReady(model) }

    func start() {
        guard !started else { return }
        started = true
        models.objectWillChange.sink { [weak self] _ in DispatchQueue.main.async { self?.refresh() } }.store(in: &bag)
        ai.objectWillChange.sink { [weak self] _ in DispatchQueue.main.async { self?.refresh() } }.store(in: &bag)
        install()
    }

    /// Lance (ou relance après une erreur) les téléchargements manquants.
    func install() {
        let model = speechModel
        switch models.status(model) {
        case .notInstalled, .failed: models.download(model)
        case .installed: models.warmUp(model)
        case .downloading: break
        }
        if settings.aiEnabled, settings.aiBackend == .embedded {
            if LocalLLM.model(settings.aiLocalModelID) == nil { settings.aiLocalModelID = Self.defaultLLM }
            if let llm = LocalLLM.model(settings.aiLocalModelID), !ai.installed.contains(llm.id),
               ai.downloadProgress[llm.id] == nil {
                ai.download(llm)
            } else {
                ai.warmUp(settings: settings)
            }
        }
        refresh()
    }

    private func refresh() {
        var list: [Item] = []
        let model = speechModel
        switch models.status(model) {
        case .downloading(let p):
            list.append(Item(id: "asr", title: model.name, detail: "Transcription, \(model.sizeLabel)", progress: p, error: nil))
        case .failed(let message):
            list.append(Item(id: "asr", title: model.name, detail: "Transcription", progress: nil, error: message))
        case .notInstalled:
            list.append(Item(id: "asr", title: model.name, detail: "Transcription, \(model.sizeLabel)", progress: 0, error: nil))
        case .installed:
            list.append(Item(id: "asr", title: model.name, detail: "Transcription", progress: nil, error: nil))
        }
        if settings.aiEnabled, settings.aiBackend == .embedded, let llm = LocalLLM.model(settings.aiLocalModelID) {
            if let p = ai.downloadProgress[llm.id] {
                list.append(Item(id: "llm", title: llm.name, detail: "Nettoyage et modes, \(llm.sizeLabel)", progress: p, error: nil))
            } else if ai.installed.contains(llm.id) {
                list.append(Item(id: "llm", title: llm.name, detail: "Nettoyage et modes", progress: nil, error: nil))
            } else {
                list.append(Item(id: "llm", title: llm.name, detail: "Nettoyage et modes", progress: nil,
                                 error: ai.lastError ?? "Pas encore téléchargé"))
            }
        }
        items = list
    }
}
