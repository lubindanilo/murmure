import NaturalLanguage
import AppKit
import SwiftUI
import Translation

/// Traduction avec le moteur d'Apple (macOS 15) : gratuite, sur l'appareil, hors ligne
/// une fois la langue téléchargée.
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

        let status = await LanguageAvailability().status(from: src ?? Locale.Language(identifier: "fr"), to: dst)
        if status == .unsupported {
            throw MurmureError.unsupported("La traduction vers \(Languages.name(target)) n'est pas prise en charge.")
        }
        if status == .supported {
            throw MurmureError.unsupported("Téléchargez la langue \(Languages.name(target)) dans Réglages > Modes > Traduction.")
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

    static func status(from source: String, to target: String) async -> LanguageAvailability.Status {
        await LanguageAvailability().status(from: Locale.Language(identifier: source == "auto" ? "fr" : source),
                                            to: Locale.Language(identifier: target))
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

/// Bouton visible qui télécharge une paire de langues (le système affiche sa propre feuille).
struct TranslationDownloadButton: View {
    let source: String
    let target: String
    @State private var configuration: TranslationSession.Configuration?
    @State private var status: LanguageAvailability.Status?

    var body: some View {
        HStack(spacing: 8) {
            switch status {
            case .installed:
                Label("Langue installée, fonctionne hors ligne", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            case .supported:
                Button("Télécharger \(Languages.name(target))") {
                    configuration = TranslationSession.Configuration(
                        source: Locale.Language(identifier: source == "auto" ? "fr" : source),
                        target: Locale.Language(identifier: target))
                }
                .controlSize(.small)
            case .unsupported:
                Text("Paire de langues non prise en charge par Apple").font(.caption).foregroundStyle(Theme.voice)
            case nil:
                ProgressView().controlSize(.small)
            @unknown default:
                EmptyView()
            }
        }
        .translationTask(configuration) { session in
            try? await session.prepareTranslation()
            status = await Translator.status(from: source, to: target)
        }
        .task(id: target) { status = await Translator.status(from: source, to: target) }
    }
}
