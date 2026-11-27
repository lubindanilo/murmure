import AVFoundation
import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case general, modes, dictionary, license
    var id: String { rawValue }

    /// Les anciens liens murmure://tab/ai ouvrent Général.
    init?(rawValue: String) {
        switch rawValue {
        case "general", "ai", "models": self = .general
        case "modes": self = .modes
        case "dictionary", "corrections": self = .dictionary
        case "history": self = .general
        case "license": self = .license
        default: return nil
        }
    }

    var title: String {
        switch self {
        case .general: return "Général"
        case .modes: return "Modes"
        case .dictionary: return "Corrections"
        case .license: return "Licence"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape.fill"
        case .modes: return "square.stack.fill"
        case .dictionary: return "text.badge.checkmark"
        case .license: return "key.fill"
        }
    }

    /// Une couleur par section, comme dans Réglages Système.
    var color: Color {
        switch self {
        case .general: return Color(white: 0.55)
        case .modes: return Theme.voice
        case .dictionary: return .blue
        case .license: return .green
        }
    }
}

/// Pastille colorée avec un symbole blanc, à la façon de Réglages Système.
struct SettingsIcon: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 22

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.27, style: .continuous).fill(color.gradient))
            .accessibilityHidden(true)
    }
}

/// Barre du haut des sous-pages : retour à gauche, titre au centre.
/// La fenêtre n'a pas de barre d'outils ; le retour est donc dans le contenu.
struct SubpageBar<Title: View>: View {
    let back: String
    let action: () -> Void
    @ViewBuilder var title: () -> Title

    var body: some View {
        ZStack {
            title()
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .frame(maxWidth: 260)
            HStack {
                Button(action: action) {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
                        if !back.isEmpty { Text(back) }
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 26)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.voice)
                .keyboardShortcut("[", modifiers: .command)
                .help("Retour (⌘[)")
                .accessibilityLabel(back.isEmpty ? "Retour" : back)
                Spacer()
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
    }
}

extension View {
    /// Sous-page : barre de retour en haut, contenu en dessous, sans bouton système.
    func subpage(title: String, back: String, action: @escaping () -> Void) -> some View {
        subpage(back: back, action: action) { Text(title) }
    }

    /// Sous-page dont le titre est une vue (par exemple le nom d'un mode, modifiable sur place).
    func subpage<Title: View>(back: String, action: @escaping () -> Void,
                              @ViewBuilder title: @escaping () -> Title) -> some View {
        VStack(spacing: 0) {
            SubpageBar(back: back, action: action, title: title)
            Divider().opacity(0.5)
            self.scrollContentBackground(.hidden)
        }
        .background(Palette.panel)
        .navigationBarBackButtonHidden(true)
    }
}

