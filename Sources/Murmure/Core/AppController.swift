import AppKit
import Combine
import Foundation

/// Orchestration : touche → enregistrement → transcription → mode (scripts, IA locale, traduction) → sortie.
@MainActor
final class AppController: ObservableObject {
    static let shared = AppController()

    enum Phase: Equatable {
        case idle
        case recording(handsFree: Bool)
        case transcribing
        case polishing(String)
        case translating(String)
        case done(String)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var level: Float = 0
    @Published private(set) var recordingStart: Date?
    @Published private(set) var lastText: String?
    /// Mode de la dictée en cours (affiché dans le panneau, modifiable pendant l'enregistrement).
    @Published var currentMode: Mode?

    let settings = Settings.shared
    let models = ModelManager.shared
    let ai = PostProcessor.shared
    let history = HistoryStore.shared
    let modes = ModeStore.shared
    let license = LicenseManager.shared

    private let recorder = AudioRecorder()
    private let hotkey = HotkeyMonitor()
    private var pressDate: Date?
    private var pressedKey: TriggerKey?
    private var context = DictationContext()
    /// Mode imposé pour cette dictée (choisi dans le panneau ou par un lien murmure://).
    private var forcedModeID: UUID?
    private var bag = Set<AnyCancellable>()
    private lazy var hud = HUDController(controller: self)

    private init() {}

    var selectedModel: SpeechModel {
        ModelCatalog.model(settings.selectedModelID) ?? ModelCatalog.local[0]
    }

    func start() {
        recorder.onLevel = { [weak self] value in
            Task { @MainActor in
                guard let self else { return }
                // Lissage : montée rapide, descente douce.
                self.level = value > self.level ? value : self.level * 0.82 + value * 0.18
            }
        }
        hotkey.onPress = { [weak self] key in Task { @MainActor in self?.keyPressed(key) } }
        hotkey.onRelease = { [weak self] key in Task { @MainActor in self?.keyReleased(key) } }
        hotkey.onEscape = { [weak self] in Task { @MainActor in self?.cancel() } }
        hotkey.onInterrupted = { [weak self] in Task { @MainActor in self?.interrupted() } }
        refreshKeys()
        hotkey.start()

        settings.$triggerKey.dropFirst().sink { [weak self] _ in
            Task { @MainActor in self?.refreshKeys() }
        }.store(in: &bag)
        modes.$modes.dropFirst().sink { [weak self] _ in
            Task { @MainActor in self?.refreshKeys() }
        }.store(in: &bag)

        Setup.shared.start()
        license.refresh()
    }

    private func refreshKeys() {
        hotkey.keys = modes.shortcutKeys.union([settings.triggerKey])
    }

    /// Relance la surveillance du clavier (après l'octroi de l'autorisation Accessibilité).
    func restartHotkey() { hotkey.start() }

    // MARK: Touches

    private func keyPressed(_ key: TriggerKey) {
        switch phase {
        case .recording(let handsFree):
            if handsFree || settings.triggerMode == .toggle { finishRecording() }
        case .transcribing, .polishing, .translating:
            return
        default:
            pressDate = Date()
            pressedKey = key == settings.triggerKey ? nil : key
            beginRecording()
        }
    }

    private func keyReleased(_ key: TriggerKey) {
        guard case .recording(let handsFree) = phase, !handsFree, settings.triggerMode == .hold else { return }
        // Un appui bref passe en mode mains libres : on parle, puis on rappuie pour finir.
        if let pressDate, Date().timeIntervalSince(pressDate) < 0.3 {
            phase = .recording(handsFree: true)
            return
        }
        finishRecording()
    }

    /// La touche faisait partie d'un raccourci clavier (⌥+lettre) : on annule sans bruit.
    private func interrupted() {
        guard case .recording = phase, let pressDate, Date().timeIntervalSince(pressDate) < 0.6 else { return }
        cancel(silently: true)
    }

    // MARK: Liens murmure://, menu

    func toggleFromMenu(mode: UUID? = nil) {
        switch phase {
        case .recording: finishRecording()
        case .transcribing, .polishing, .translating: return
        default:
            pressDate = .distantPast
            pressedKey = nil
            forcedModeID = mode
            beginRecording(handsFree: true)
        }
    }

    func startFromLink(mode: UUID?) {
        guard case .idle = phase else { return }
        toggleFromMenu(mode: mode)
    }

    /// Change le mode de la dictée en cours (menu du panneau).
    func switchCurrentMode(to mode: Mode) {
        forcedModeID = mode.id
        currentMode = mode
    }

    // MARK: Cycle

    private func beginRecording(handsFree: Bool = false) {
        guard Setup.shared.isReady(selectedModel) else {
            fail("Murmure termine l'installation de \(selectedModel.name). Réessayez dans un instant.")
            PanelController.shared.show(.general)
            return
        }
        guard license.canDictate else {
            fail("Votre essai gratuit est terminé. Activez Murmure pour continuer à dicter.")
            PanelController.shared.show(.license)
            return
        }
        guard AudioRecorder.permission != .denied else {
            fail("Murmure n'a pas accès au micro. Autorisez-le dans Réglages Système > Confidentialité > Micro.")
            return
        }
        context = DictationContext.capture()
        do {
            try recorder.start()
        } catch {
            fail(error.localizedDescription)
            return
        }
        recordingStart = Date()
        phase = .recording(handsFree: handsFree || settings.triggerMode == .toggle)
        currentMode = resolvedMode()
        // Retour visuel et sonore un peu différé : un raccourci clavier fait avec la touche de dictée
        // (⌘C avec ⌘ droite) annule l'enregistrement avant, sans bip ni panneau.
        let started = recordingStart
        let delay: TimeInterval = handsFree ? 0 : 0.2
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, case .recording = self.phase, self.recordingStart == started else { return }
            self.play("Tink")
            self.hud.show()
        }

        // L'URL du navigateur arrive un peu plus tard (AppleScript) : le mode peut alors changer.
        let wantsURL = modes.modes.contains { !$0.websites.isEmpty || $0.includeBrowserURL }
        if wantsURL, let bundle = context.appBundleID, DictationContext.browsers[bundle] != nil {
            Task {
                let url = await DictationContext.browserURL(bundleID: bundle)
                guard case .recording = self.phase else { return }
                self.context.browserURL = url
                self.currentMode = self.resolvedMode()
            }
        }
    }

    private func resolvedMode() -> Mode {
        if let forced = modes.mode(forcedModeID) { return forced }
        return modes.resolve(shortcut: pressedKey, context: context)
    }

    func cancel(silently: Bool = false) {
        guard case .recording = phase else { return }
        recorder.stop()
        level = 0
        phase = .idle
        forcedModeID = nil
        if !silently { play("Funk") }
        hud.hide()
    }

    func finishRecording() {
        guard case .recording = phase else { return }
        let samples = recorder.stop()
        level = 0
        play("Pop")
        let duration = Double(samples.count) / AudioRecorder.sampleRate
        let mode = resolvedMode()
        forcedModeID = nil
        guard duration > 0.35 else {
            phase = .idle
            hud.hide()
            return
        }
        phase = .transcribing
        let context = self.context
        Task { [weak self] in
            await self?.run(samples: samples, duration: duration, mode: mode, context: context)
        }
    }

    private func run(samples: [Float], duration: TimeInterval, mode initialMode: Mode, context: DictationContext) async {
        let started = Date()
        let model = selectedModel
        var mode = initialMode
        do {
            let engine = try await models.engine(for: model)
            let language = settings.language == "auto" || model.isEnglishOnly ? nil : settings.language
            var text = try await engine.transcribe(samples, language: language, vocabulary: settings.dictionary)
            text = TextProcessing.apply(text, replacements: [])
            license.recordUsage(seconds: duration)

            // Le mot déclencheur est prioritaire sur tout le reste.
            if let (triggered, rest) = modes.triggerMatch(in: text) {
                mode = triggered
                text = rest
                currentMode = triggered
            }
            guard !text.isEmpty else { finishQuietly(); return }

            if mode.cleanup || !mode.instructions.isEmpty { text = TextProcessing.removeFillers(text) }
            guard !text.isEmpty else { finishQuietly(); return }
            let rawText = text
            var output = mode.outputMode
            var skipAI = false
            let audioFile = (mode.scriptBefore.isEmpty && mode.scriptAfter.isEmpty) ? nil : saveAudio(samples)
            defer { if let audioFile { try? FileManager.default.removeItem(at: audioFile) } }

            if mode.replacementTiming != .after {
                text = TextProcessing.apply(text, replacements: settings.replacements)
            }

            // Script avant l'IA : il peut sauter l'IA, changer la sortie ou basculer de mode.
            if !mode.scriptBefore.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let r = try await ScriptRunner.run(mode.scriptBefore, input: text, context: context, mode: mode,
                                                   audioDuration: duration, audioFile: audioFile)
                guard !r.output.isEmpty else { finishQuietly(); return }
                text = r.output
                skipAI = r.skipAI
                if let name = r.switchMode, let next = modes.mode(named: name) { mode = next; output = next.outputMode }
                if let o = r.outputMode { output = o }
            }

            // Ton automatique : seulement pour le mode principal, sans consignes personnalisées.
            let tone = settings.autoTone && mode.isMain ? AutoTone.detect(bundleID: context.appBundleID) : nil
            if settings.aiEnabled, mode.usesAI, !skipAI {
                phase = .polishing(tone?.label ?? mode.name)
                do {
                    text = try await ai.process(text, mode: mode, context: context, settings: settings, tone: tone)
                } catch {
                    // L'IA n'est pas disponible : on insère quand même la transcription.
                    NSLog("Murmure IA : \(error.localizedDescription)")
                }
            }

            if let target = mode.translateTo ?? (settings.writeInEnglish ? "en" : nil) {
                phase = .translating(Languages.name(target))
                text = try await Translator.shared.translate(text, from: settings.language, to: target)
            }

            if !mode.scriptAfter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let r = try await ScriptRunner.run(mode.scriptAfter, input: text, context: context, mode: mode,
                                                   audioDuration: duration, audioFile: audioFile)
                guard !r.output.isEmpty else { finishQuietly(); return }
                text = r.output
                if let o = r.outputMode { output = o }
            }

            if mode.replacementTiming != .before {
                text = TextProcessing.apply(text, replacements: settings.replacements)
            }

            TextInserter.insert(text, mode: output, restoreClipboard: settings.restoreClipboard)
            lastText = text
            history.add(HistoryEntry(date: Date(), text: text, rawText: text == rawText ? nil : rawText,
                                     modelName: model.name, modeName: mode.isMain ? nil : mode.name,
                                     duration: duration, processingTime: Date().timeIntervalSince(started)),
                        limit: settings.historyLimit)
            phase = .done(output == .copy ? "Copié" : output == .historyOnly ? "Enregistré" : "Inséré")
            hud.hide(after: output == .copy || output == .historyOnly ? 1.4 : 0.5)
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func finishQuietly() {
        phase = .idle
        hud.hide()
    }

    private func saveAudio(_ samples: [Float]) -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("murmure-\(UUID().uuidString).wav")
        return (try? WAV.encode(samples, sampleRate: Int(AudioRecorder.sampleRate)).write(to: url)) != nil ? url : nil
    }

    private func fail(_ message: String) {
        phase = .failed(message)
        hud.show()
        hud.hide(after: 4)
    }

    func resetIfFinished() {
        switch phase {
        case .done, .failed: phase = .idle
        default: break
        }
    }

    private func play(_ name: String) {
        guard settings.playSounds else { return }
        NSSound(named: NSSound.Name(name))?.play()
    }
}
