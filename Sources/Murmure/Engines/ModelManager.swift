import Foundation

/// Téléchargement, chargement et suppression des modèles locaux.
@MainActor
final class ModelManager: ObservableObject {
    static let shared = ModelManager()

    enum Status: Equatable {
        case notInstalled
        case downloading(Double)
        case installed
        case failed(String)
    }

    @Published private(set) var status: [String: Status] = [:]
    @Published private(set) var loadingModelID: String?

    private var engines: [String: TranscriptionEngine] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]

    static let root: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("Murmure/Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    private init() {
        for model in ModelCatalog.local where model.needsDownload {
            status[model.id] = isMarkedInstalled(model.id) ? .installed : .notInstalled
        }
    }

    func status(_ model: SpeechModel) -> Status {
        guard model.needsDownload else { return .installed }
        return status[model.id] ?? .notInstalled
    }

    func isReady(_ model: SpeechModel) -> Bool { status(model) == .installed }

    // MARK: Téléchargement

    func download(_ model: SpeechModel) {
        guard model.needsDownload, tasks[model.id] == nil else { return }
        status[model.id] = .downloading(0)
        tasks[model.id] = Task { [weak self] in
            guard let self else { return }
            do {
                let engine = try await self.makeEngine(model) { fraction in
                    Task { @MainActor in
                        if case .downloading = self.status[model.id] {
                            self.status[model.id] = .downloading(min(fraction, 0.99))
                        }
                    }
                }
                self.engines[model.id] = engine
                self.markInstalled(model.id, true)
                self.status[model.id] = .installed
            } catch is CancellationError {
                self.status[model.id] = .notInstalled
            } catch {
                self.status[model.id] = .failed(error.localizedDescription)
            }
            self.tasks[model.id] = nil
        }
    }

    func cancel(_ model: SpeechModel) {
        tasks[model.id]?.cancel()
        tasks[model.id] = nil
        status[model.id] = .notInstalled
    }

    func delete(_ model: SpeechModel) {
        engines[model.id] = nil
        markInstalled(model.id, false)
        try? FileManager.default.removeItem(at: directory(for: model))
        status[model.id] = .notInstalled
    }

    // MARK: Chargement

    /// Renvoie le moteur prêt à transcrire, en le chargeant si besoin.
    func engine(for model: SpeechModel) async throws -> TranscriptionEngine {
        if let engine = engines[model.id] { return engine }
        switch model.kind {
        case .cloud(let provider, let name):
            let engine = CloudEngine(provider: provider, model: name)
            engines[model.id] = engine
            return engine
        case .appleSpeech:
            let engine = AppleSpeechEngine()
            engines[model.id] = engine
            return engine
        default:
            guard isReady(model) else { throw MurmureError.modelNotInstalled(model.name) }
            loadingModelID = model.id
            defer { loadingModelID = nil }
            let engine = try await makeEngine(model, progress: { _ in })
            engines[model.id] = engine
            return engine
        }
    }

    /// Précharge le modèle choisi pour que la première dictée soit rapide.
    func warmUp(_ model: SpeechModel) {
        guard engines[model.id] == nil, isReady(model) else { return }
        Task { _ = try? await engine(for: model) }
    }

    /// Libère les modèles qui ne sont plus sélectionnés.
    func unloadAll(except id: String) {
        engines = engines.filter { $0.key == id }
    }

    private func makeEngine(_ model: SpeechModel, progress: @escaping (Double) -> Void) async throws -> TranscriptionEngine {
        let dir = directory(for: model)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        switch model.kind {
        case .whisper(let variant):
            let folder: URL
            if let saved = UserDefaults.standard.string(forKey: "whisperFolder.\(model.id)"),
               FileManager.default.fileExists(atPath: saved) {
                folder = URL(fileURLWithPath: saved)
            } else {
                folder = try await WhisperEngine.download(variant: variant, into: dir, progress: progress)
                UserDefaults.standard.set(folder.path, forKey: "whisperFolder.\(model.id)")
            }
            return try await WhisperEngine(folder: folder)
        case .parakeet(let version):
            return try await ParakeetEngine(version: version, directory: dir, progress: progress)
        case .parakeetUnified:
            return try await ParakeetUnifiedEngine(directory: dir, progress: progress)
        case .nemotronLite:
            guard #available(macOS 15, *) else { throw MurmureError.unsupported("Nemotron demande macOS 15.") }
            return try await NemotronEngine(progress: progress)
        case .appleSpeech:
            return AppleSpeechEngine()
        case .cloud(let provider, let name):
            return CloudEngine(provider: provider, model: name)
        }
    }

    private func directory(for model: SpeechModel) -> URL {
        Self.root.appendingPathComponent(model.id, isDirectory: true)
    }

    private func isMarkedInstalled(_ id: String) -> Bool {
        UserDefaults.standard.bool(forKey: "installed.\(id)")
    }

    private func markInstalled(_ id: String, _ value: Bool) {
        UserDefaults.standard.set(value, forKey: "installed.\(id)")
        if !value { UserDefaults.standard.removeObject(forKey: "whisperFolder.\(id)") }
    }
}
