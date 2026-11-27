import NaturalLanguage
import AppKit
import SwiftUI
import Translation

/// Traduction sur le Mac : le moteur d'Apple (macOS 15) quand la langue est déjà installée sur le système,
/// sinon le LLM local de Murmure. Rien à télécharger pour l'utilisateur.
///
/// Le framework ne fournit une session de traduction qu'à une vue SwiftUI (.translationTask) :
/// on garde donc une vue invisible dans une fenêtre transparente, et on lui confie les textes.
@MainActor
final class Translator: ObservableObject {
    static let shared = Translator()

    @Published fileprivate var configuration: TranslationSession.Configuration?
    private var pending: [(text: String, continuation: CheckedContinuation<String, Error>)] = []
    private var window: NSWindow?

    func translate(_ text: String, from source: String?, to target: String) async throws -> String {
        // La langue parlée est détectée sur le texte ; le réglage ne sert que si la détection échoue.
        let detected = NLLanguageRecognizer.dominantLanguage(for: text)?.rawValue
        let src = (detected ?? source).flatMap { $0 == "auto" ? nil : Locale.Language(identifier: $0) }
        let dst = Locale.Language(identifier: target)
        if let src, src.languageCode == dst.languageCode { return text }

        // Le moteur d'Apple ne sert que si macOS a déjà la langue. Sinon le LLM local, installé avec
        // l'app, traduit : on ne demande jamais de télécharger une langue.
        let status = await LanguageAvailability().status(from: src ?? Locale.Language(identifier: "fr"), to: dst)
        if status != .installed {
            let settings = Settings.shared
            guard PostProcessor.shared.canComplete(settings: settings) else {
                throw MurmureError.unsupported("La traduction attend la fin de l'installation du modèle de langage.")
            }
            return try await PostProcessor.shared.translate(text, to: target, settings: settings)
        }

        ensureHost()
        return try await withCheckedThrowingContinuation { cont in
            pending.append((text, cont))
            let config = TranslationSession.Configuration(source: src, target: dst)
            if configuration?.source == config.source, configuration?.target == config.target {
                configuration?.invalidate()
            } else {
                configuration = config
            }
        }
    }

    fileprivate func drain(_ session: TranslationSession) async {
        while !pending.isEmpty {
            let job = pending.removeFirst()
            do {
                job.continuation.resume(returning: try await session.translate(job.text).targetText)
            } catch {
                job.continuation.resume(throwing: error)
            }
        }
    }

    private func ensureHost() {
        guard window == nil else { return }
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 1, height: 1),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle, .transient]
        window.contentView = NSHostingView(rootView: TranslationHost(translator: self))
        window.orderFrontRegardless()
        self.window = window
    }
}

private struct TranslationHost: View {
    @ObservedObject var translator: Translator

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .translationTask(translator.configuration) { session in
                await translator.drain(session)
            }
    }
}
