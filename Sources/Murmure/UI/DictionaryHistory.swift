import SwiftUI

/// Corrections : ce que Murmure entend souvent de travers, et ce qu'il doit écrire.
/// Appliquées mot pour mot à chaque dictée, et données à l'IA comme orthographe de référence.
struct CorrectionsSettings: View {
    @EnvironmentObject var settings: Settings
    @State private var adding = false
    @State private var heard = ""
    @State private var written = ""
    @State private var hovered: UUID?
    @FocusState private var focus: Field?

    private enum Field { case heard, written }

    private var canAdd: Bool {
        !heard.trimmingCharacters(in: .whitespaces).isEmpty && !written.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            PanelSubpageBar(title: "Corrections", back: { PanelController.shared.router.path.removeAll() }) {
                Button {
                    adding.toggle()
                    if adding { focus = .heard }
                } label: {
                    Image(systemName: adding ? "xmark" : "plus").font(.system(size: 13, weight: .semibold))
                        .frame(width: 28, height: 28).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(adding ? "Annuler" : "Ajouter une correction")
            }
            VStack(spacing: 0) {
                // Titres de colonnes seulement quand il y a quelque chose à aligner dessous.
                if !settings.replacements.isEmpty || adding {
                    HStack {
                        Text("Entendu").frame(maxWidth: .infinity, alignment: .leading)
                        Text("Écrit").frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 30)
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.muted)
                    .padding(.top, 12)
                    .padding(.bottom, 6)
                }

                if adding {
                    HStack(spacing: 8) {
                        TextField("cloud code", text: $heard)
                            .textFieldStyle(.roundedBorder)
                            .focused($focus, equals: .heard)
                            .onSubmit { focus = .written }
                        Image(systemName: "arrow.right").font(.system(size: 11)).foregroundStyle(Palette.muted)
                        TextField("Claude Code", text: $written)
                            .textFieldStyle(.roundedBorder)
                            .focused($focus, equals: .written)
                            .onSubmit(add)
                    }
                    .font(.system(size: 13))
                    .padding(.vertical, 8)
                    .transition(.opacity)
                }

                if settings.replacements.isEmpty && !adding {
                    Text("Ajoutez les mots que Ramage écrit de travers : noms propres, marques, jargon.")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 14)
                }

                ForEach(settings.replacements) { r in
                    HStack(spacing: 8) {
                        Text(r.from).frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "arrow.right").font(.system(size: 11)).foregroundStyle(Palette.muted)
                        Text(r.to.isEmpty ? "(supprimé)" : r.to).fontWeight(.medium)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button {
                            settings.replacements.removeAll { $0.id == r.id }
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(Palette.muted)
                        }
                        .buttonStyle(.plain)
                        .opacity(hovered == r.id ? 1 : 0)
                        .help("Supprimer")
                        .accessibilityLabel("Supprimer \(r.from)")
                    }
                    .font(.system(size: 13))
                    .frame(height: 40)
                    .contentShape(Rectangle())
                    .onHover { hovered = $0 ? r.id : (hovered == r.id ? nil : hovered) }
                    .contextMenu { Button("Supprimer", role: .destructive) { settings.replacements.removeAll { $0.id == r.id } } }
                    .overlay(alignment: .top) { Divider().overlay(Palette.hairline) }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
        .animation(Theme.quick, value: adding)
    }

    private func add() {
        guard canAdd else { return }
        settings.replacements.insert(WordReplacement(
            from: heard.trimmingCharacters(in: .whitespaces),
            to: written.trimmingCharacters(in: .whitespaces)), at: 0)
        heard = ""; written = ""
        adding = false
    }
}

/// Mots en jetons supprimables, sur plusieurs lignes (apps et sites des modes).
struct WrapLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 400
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 { x = 0; y += rowH + spacing; rowH = 0 }
            x += size.width + spacing
            rowH = max(rowH, size.height)
        }
        return CGSize(width: width, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowH = max(rowH, size.height)
        }
    }
}
