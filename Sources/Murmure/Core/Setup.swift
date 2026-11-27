import Combine
import Foundation

/// Installation au premier lancement, dans cet ordre : Parakeet Ultra pour la transcription,
/// Murmure Cleanup 1 pour le nettoyage de la dictée, puis le LLM des modes. Rien à choisir.
@MainActor
final class Setup: ObservableObject {
    static let shared = Setup()

    /// LLM installé par défaut pour les modes qui ont des consignes.
    static let defaultLLM = "qwen2.5-1.5b"

    private let models = ModelManager.shared
    private let ai = PostProcessor.shared
    private let settings = Settings.shared
    private var bag = Set<AnyCancellable>()
    private var started = false
    /// Le LLM attend la fin de la transcription : les deux en même temps se partagent la connexion,
    /// et le modèle de transcription (le seul qui bloque la première dictée) mettait trois fois plus longtemps.
    private var llmQueued = false
    /// Cleanup 1 attend lui aussi la transcription ; le LLM des modes attend Cleanup 1.
    private var cleanupQueued = false
    private let cleanup = LocalLLM.cleanup

    /// Cleanup 1 installé, ou abandonné (échec) : le LLM des modes peut passer.
    private var cleanupSettled: Bool {
        !settings.aiEnabled || ai.installed.contains(cleanup.id) || (!cleanupQueued && ai.downloadProgress[cleanup.id] == nil)
    }

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
        if settings.aiEnabled {
            if ai.installed.contains(cleanup.id) {
                CleanupModel.shared.warmUp()
            } else if ai.downloadProgress[cleanup.id] == nil {
                if models.isReady(model) { ai.download(cleanup) } else { cleanupQueued = true }
            }
        }
        if settings.aiEnabled, settings.aiBackend == .embedded {
            if LocalLLM.model(settings.aiLocalModelID) == nil { settings.aiLocalModelID = Self.defaultLLM }
            if let llm = LocalLLM.model(settings.aiLocalModelID), !ai.installed.contains(llm.id),
               ai.downloadProgress[llm.id] == nil {
                if models.isReady(model), cleanupSettled { ai.download(llm) } else { llmQueued = true }
            } else {
                ai.warmUp(settings: settings)
            }
        }
        refresh()
    }

    /// Transcription prête : Cleanup 1 démarre ; puis, Cleanup 1 prêt, le LLM des modes.
    private func startQueuedLLM() {
        guard models.isReady(speechModel) else { return }
        if cleanupQueued {
            cleanupQueued = false
            if !ai.installed.contains(cleanup.id), ai.downloadProgress[cleanup.id] == nil { ai.download(cleanup) }
        }
        if settings.aiEnabled, ai.installed.contains(cleanup.id) { CleanupModel.shared.warmUp() }
        guard llmQueued, cleanupSettled else { return }
        llmQueued = false
        if let llm = LocalLLM.model(settings.aiLocalModelID), !ai.installed.contains(llm.id),
           ai.downloadProgress[llm.id] == nil {
            ai.download(llm)
        }
    }

    private func refresh() {
        startQueuedLLM()
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
        if settings.aiEnabled {
            if let p = ai.downloadProgress[cleanup.id] {
                list.append(Item(id: "cleanup", title: cleanup.name, detail: "Nettoyage de la dictée, \(cleanup.sizeLabel)", progress: p, error: nil))
            } else if cleanupQueued {
                list.append(Item(id: "cleanup", title: cleanup.name, detail: "En attente de la transcription", progress: 0, error: nil))
            } else if ai.installed.contains(cleanup.id) {
                list.append(Item(id: "cleanup", title: cleanup.name, detail: "Nettoyage de la dictée", progress: nil, error: nil))
            } else {
                list.append(Item(id: "cleanup", title: cleanup.name, detail: "Nettoyage de la dictée", progress: nil,
                                 error: ai.lastError ?? "Pas encore téléchargé"))
            }
        }
        if settings.aiEnabled, settings.aiBackend == .embedded, let llm = LocalLLM.model(settings.aiLocalModelID) {
            if let p = ai.downloadProgress[llm.id] {
                list.append(Item(id: "llm", title: llm.name, detail: "Modes avec consignes, \(llm.sizeLabel)", progress: p, error: nil))
            } else if llmQueued {
                list.append(Item(id: "llm", title: llm.name, detail: "En attente", progress: 0, error: nil))
            } else if ai.installed.contains(llm.id) {
                list.append(Item(id: "llm", title: llm.name, detail: "Modes avec consignes", progress: nil, error: nil))
            } else {
                list.append(Item(id: "llm", title: llm.name, detail: "Modes avec consignes", progress: nil,
                                 error: ai.lastError ?? "Pas encore téléchargé"))
            }
        }
        items = list
    }
}
