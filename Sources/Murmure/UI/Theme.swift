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

    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
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
