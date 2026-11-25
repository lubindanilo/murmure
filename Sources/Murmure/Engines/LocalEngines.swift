import AVFoundation
import FluidAudio
import Foundation
import Speech
import WhisperKit

/// Un moteur chargé en mémoire, prêt à transcrire.
protocol TranscriptionEngine: AnyObject {
    func transcribe(_ samples: [Float], language: String?, vocabulary: [String]) async throws -> String
}

// MARK: - Whisper (WhisperKit, Core ML sur Neural Engine)

final class WhisperEngine: TranscriptionEngine {
    private let pipe: WhisperKit

    init(folder: URL) async throws {
        let config = WhisperKitConfig(modelFolder: folder.path, verbose: false, logLevel: .error,
                                      prewarm: true, load: true, download: false)
        pipe = try await WhisperKit(config)
    }

    func transcribe(_ samples: [Float], language: String?, vocabulary: [String]) async throws -> String {
        var options = DecodingOptions(
            task: .transcribe,
            language: language,
            temperature: 0,
            usePrefillPrompt: true,
            detectLanguage: language == nil,
            skipSpecialTokens: true,
            withoutTimestamps: true
        )
        // Le dictionnaire personnel sert d'invite : Whisper reprend l'orthographe des mots fournis.
        if !vocabulary.isEmpty, let tokenizer = pipe.tokenizer {
            let prompt = " " + vocabulary.joined(separator: ", ") + "."
            options.promptTokens = tokenizer.encode(text: prompt)
                .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
        }
        let results = try await pipe.transcribe(audioArray: samples, decodeOptions: options)
        return results.map(\.text).joined(separator: " ")
    }

    static func download(variant: String, into base: URL, progress: @escaping (Double) -> Void) async throws -> URL {
        try await WhisperKit.download(variant: variant, downloadBase: base) { p in
            progress(p.fractionCompleted)
        }
    }
}

// MARK: - Parakeet et dérivés (FluidAudio, Neural Engine)

final class ParakeetEngine: TranscriptionEngine {
    private let manager: AsrManager

    static func version(_ name: String) -> AsrModelVersion {
        switch name {
        case "v2": return .v2
        case "ultra": return .ultra
        case "redux": return .redux
        case "phonon2": return .phonon2
        case "bark3": return .bark3
        default: return .v3
        }
    }

    init(version: String, directory: URL, progress: ((Double) -> Void)? = nil) async throws {
        let models = try await AsrModels.downloadAndLoad(
            to: directory, version: Self.version(version),
            progressHandler: { p in progress?(p.fractionCompleted) })
        manager = AsrManager(config: .default)
        try await manager.loadModels(models)
    }

    func transcribe(_ samples: [Float], language: String?, vocabulary: [String]) async throws -> String {
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(samples, decoderState: &state)
        return result.text
    }
}

final class ParakeetUnifiedEngine: TranscriptionEngine {
    private let manager = UnifiedAsrManager()

    init(directory: URL, progress: ((Double) -> Void)? = nil) async throws {
        try await manager.loadModels(to: directory, progressHandler: { p in progress?(p.fractionCompleted) })
    }

    func transcribe(_ samples: [Float], language: String?, vocabulary: [String]) async throws -> String {
        try await manager.transcribe(samples)
    }
}

@available(macOS 15, *)
final class NemotronEngine: TranscriptionEngine {
    private let manager: NemotronTranscribeLiteManager

    init(progress: ((Double) -> Void)? = nil) async throws {
        manager = try await NemotronTranscribeLiteManager.load(progressHandler: { p in progress?(p.fractionCompleted) })
    }

    func transcribe(_ samples: [Float], language: String?, vocabulary: [String]) async throws -> String {
        try await manager.transcribe(audio: samples).text
    }
}

// MARK: - Apple Speech (SFSpeechRecognizer)

final class AppleSpeechEngine: TranscriptionEngine {
    static func requestPermission() async -> Bool {
        await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0 == .authorized) }
        }
    }

    func transcribe(_ samples: [Float], language: String?, vocabulary: [String]) async throws -> String {
        let locale = Locale(identifier: language ?? Locale.current.identifier)
        guard let recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer(), recognizer.isAvailable else {
            throw MurmureError.unsupported("La reconnaissance vocale d'Apple n'est pas disponible pour cette langue.")
        }
        if SFSpeechRecognizer.authorizationStatus() != .authorized {
            guard await Self.requestPermission() else {
                throw MurmureError.unsupported("Autorisez la reconnaissance vocale dans Réglages Système > Confidentialité.")
            }
        }
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioRecorder.sampleRate,
                                   channels: 1, interleaved: false)!
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
            throw MurmureError.emptyAudio
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            buffer.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        request.contextualStrings = vocabulary
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        request.append(buffer)
        request.endAudio()

        return try await withCheckedThrowingContinuation { cont in
            var resumed = false
            recognizer.recognitionTask(with: request) { result, error in
                guard !resumed else { return }
                if let error {
                    resumed = true
                    cont.resume(throwing: error)
                } else if let result, result.isFinal {
                    resumed = true
                    cont.resume(returning: result.bestTranscription.formattedString)
                }
            }
        }
    }
}
