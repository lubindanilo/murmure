import AVFoundation
import Foundation

/// Capture le micro et produit des échantillons Float32 mono à 16 kHz,
/// le format attendu par tous les moteurs de transcription.
final class AudioRecorder {
    static let sampleRate: Double = 16_000

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var samples: [Float] = []
    private let lock = NSLock()
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioRecorder.sampleRate,
                                             channels: 1, interleaved: false)!

    /// Niveau du micro (0...1), appelé environ 20 fois par seconde.
    var onLevel: ((Float) -> Void)?

    private(set) var isRecording = false

    static var permission: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .audio) }

    static func requestPermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    func start() throws {
        guard !isRecording else { return }
        lock.lock(); samples.removeAll(keepingCapacity: true); lock.unlock()

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw MurmureError.noMicrophone
        }
        converter = AVAudioConverter(from: inputFormat, to: targetFormat)

        input.removeTap(onBus: 0)
        let bufferSize = AVAudioFrameCount(inputFormat.sampleRate / 20)
        input.installTap(onBus: 0, bufferSize: bufferSize, format: inputFormat) { [weak self] buffer, _ in
            self?.process(buffer)
        }
        engine.prepare()
        try engine.start()
        isRecording = true
    }

    /// Arrête la capture et renvoie l'audio enregistré.
    @discardableResult
    func stop() -> [Float] {
        guard isRecording else { return [] }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        lock.lock(); defer { lock.unlock() }
        return samples
    }

    var duration: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return Double(samples.count) / Self.sampleRate
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

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
        guard error == nil, let channel = out.floatChannelData?[0] else { return }
        let count = Int(out.frameLength)
        let chunk = Array(UnsafeBufferPointer(start: channel, count: count))

        lock.lock(); samples.append(contentsOf: chunk); lock.unlock()

        // Niveau RMS converti en échelle perceptive.
        var sum: Float = 0
        for s in chunk { sum += s * s }
        let rms = count > 0 ? sqrt(sum / Float(count)) : 0
        let db = 20 * log10(max(rms, 0.000_01))
        let level = max(0, min(1, (db + 50) / 40))
        onLevel?(level)
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
