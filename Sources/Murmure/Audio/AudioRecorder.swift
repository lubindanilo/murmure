import AVFoundation
import Foundation

/// Capture le micro et produit des échantillons Float32 mono à 16 kHz,
/// le format attendu par tous les moteurs de transcription.
final class AudioRecorder: @unchecked Sendable {
    static let sampleRate: Double = 16_000

    // Le moteur et la capture courante sont réservés à cette file.
    private let queue = DispatchQueue(label: "app.murmure.audio", qos: .userInitiated)
    private lazy var engine = AVAudioEngine()
    private var capture: Capture?
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioRecorder.sampleRate,
                                             channels: 1, interleaved: false)!

    static var permission: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .audio) }

    static func requestPermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    /// Prépare l'unité audio du micro sans l'ouvrir (pas de voyant orange) : le premier
    /// démarrage d'AVAudioEngine coûte sinon quelques centaines de millisecondes.
    func prewarm() {
        queue.async {
            guard Self.permission == .authorized else { return }
            _ = self.engine.inputNode.outputFormat(forBus: 0)
        }
    }

    func start(onLevel: @escaping @MainActor @Sendable (Float) -> Void,
               onFailure: @escaping @MainActor @Sendable (Error) -> Void) {
        queue.async {
            do {
                try self.startCapture(onLevel: onLevel)
            } catch {
                DispatchQueue.main.async { onFailure(error) }
            }
        }
    }

    private func startCapture(onLevel: @escaping @MainActor @Sendable (Float) -> Void) throws {
        guard capture == nil else { return }
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
              let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw MurmureError.noMicrophone
        }

        let capture = Capture(converter: converter)
        let bufferSize = AVAudioFrameCount(inputFormat.sampleRate / 20)
        input.installTap(onBus: 0, bufferSize: bufferSize, format: inputFormat) { buffer, _ in
            guard let level = capture.process(buffer) else { return }
            DispatchQueue.main.async { onLevel(level) }
        }
        engine.prepare()
        do {
            try engine.start()
            self.capture = capture
        } catch {
            input.removeTap(onBus: 0)
            engine.stop()
            throw error
        }
    }

    /// Les demandes d'arrêt suivent toujours la demande de démarrage sur la file audio.
    func stop(completion: (@MainActor @Sendable ([Float]) -> Void)? = nil) {
        queue.async {
            var samples: [Float] = []
            if let capture = self.capture {
                self.engine.inputNode.removeTap(onBus: 0)
                self.engine.stop()
                samples = capture.finish()
                self.capture = nil
            }
            if let completion {
                let result = samples
                DispatchQueue.main.async { completion(result) }
            }
        }
    }
}

/// Chaque tap audio garde son propre convertisseur et ses propres échantillons.
private final class Capture: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let lock = NSLock()
    private var samples: [Float]?

    init(converter: AVAudioConverter) {
        self.converter = converter
        samples = []
    }

    func finish() -> [Float] {
        lock.withLock {
            let result = samples ?? []
            samples = nil
            return result
        }
    }

    func process(_ buffer: AVAudioPCMBuffer) -> Float? {
        let targetFormat = converter.outputFormat
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return nil }

        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let channel = out.floatChannelData?[0] else { return nil }
        let count = Int(out.frameLength)
        let chunk = Array(UnsafeBufferPointer(start: channel, count: count))

        lock.withLock { samples?.append(contentsOf: chunk) }

        // Niveau RMS converti en échelle perceptive.
        var sum: Float = 0
        for s in chunk { sum += s * s }
        let rms = count > 0 ? sqrt(sum / Float(count)) : 0
        let db = 20 * log10(max(rms, 0.000_01))
        return max(0, min(1, (db + 50) / 40))
    }
}

enum MurmureError: LocalizedError {
    case noMicrophone
    case modelNotInstalled(String)
    case missingAPIKey(String)
    case http(Int, String)
    case emptyAudio
    case unsupported(String)
    case llm(String)

    var errorDescription: String? {
        switch self {
        case .noMicrophone: return "Aucun micro disponible."
        case .modelNotInstalled(let name): return "\(name) n'est pas téléchargé. Ouvrez Réglages > Modèles."
        case .missingAPIKey(let provider): return "Clé API \(provider) manquante. Ajoutez-la dans Réglages > Modèles."
        case .http(let code, let body): return "Erreur du service (\(code)) : \(body.prefix(200))"
        case .emptyAudio: return "Enregistrement trop court."
        case .unsupported(let reason): return reason
        case .llm(let reason): return "Post-traitement IA : \(reason)"
        }
    }
}
