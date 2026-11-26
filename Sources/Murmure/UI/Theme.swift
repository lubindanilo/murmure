import SwiftUI

/// Une seule couleur d'accent, réservée à la voix : enregistrement, sélection, actions principales.
/// Tout le reste utilise les couleurs système pour suivre le mode clair/sombre et le contraste augmenté.
enum Theme {
    /// Vermillon : lisible sur fond clair comme sur le panneau sombre.
    static let voice = Color(red: 0.89, green: 0.30, blue: 0.20)
    static let voiceSoft = voice.opacity(0.14)

    static let hudBackground = Color(white: 0.09)
    static let hudStroke = Color.white.opacity(0.10)
    static let hudText = Color.white.opacity(0.92)
    static let hudSecondary = Color.white.opacity(0.62)

    /// Fond plat des zones d'illustration (onboarding, en-têtes).
    static let stage = Color.primary.opacity(0.035)

    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Changement d'étape : léger fondu, flou de 4 pt et 12 pt de montée ; fondu seul si les animations sont réduites.
    static var stepTransition: AnyTransition {
        if reduceMotion { return .opacity }
        return .asymmetric(
            insertion: .opacity.combined(with: .offset(y: 12)).combined(with: .modifier(active: BlurModifier(radius: 4), identity: BlurModifier(radius: 0))),
            removal: .opacity.combined(with: .offset(y: -12)).combined(with: .modifier(active: BlurModifier(radius: 4), identity: BlurModifier(radius: 0))))
    }

    static var stepAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.4, bounce: 0)
    }

    /// Changements d'état fréquents : réponse rapide, sans rebond.
    static let quick = Animation.spring(duration: 0.3, bounce: 0)
}

struct BlurModifier: ViewModifier {
    let radius: CGFloat
    func body(content: Content) -> some View { content.blur(radius: radius) }
}

/// Note sur 5 affichée en cinq segments (précision, vitesse).
struct RatingBar: View {
    let label: String
    let value: Double

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 58, alignment: .leading)
            HStack(spacing: 2) {
                ForEach(0..<5, id: \.self) { i in
                    let fill = max(0, min(1, value - Double(i)))
                    Capsule()
                        .fill(Color.primary.opacity(0.12))
                        .overlay(alignment: .leading) {
                            GeometryReader { geo in
                                Capsule().fill(Color.primary.opacity(0.7)).frame(width: geo.size.width * fill)
                            }
                        }
                        .frame(width: 10, height: 4)
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("\(label) \(value.formatted()) sur 5")
    }
}

struct SelectionMark: View {
    let selected: Bool
    let enabled: Bool

    var body: some View {
        ZStack {
            Circle().strokeBorder(selected ? Theme.voice : Color.secondary.opacity(enabled ? 0.6 : 0.25), lineWidth: 1.5)
            if selected { Circle().fill(Theme.voice).padding(4) }
        }
        .frame(width: 16, height: 16)
        .accessibilityLabel(selected ? "Sélectionné" : "Non sélectionné")
    }
}
