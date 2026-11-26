import SwiftUI

/// Corrections : ce que Murmure entend souvent de travers, et ce qu'il doit écrire.
/// Appliquées mot pour mot à chaque dictée, et données à l'IA comme orthographe de référence.
struct CorrectionsSettings: View {
    @EnvironmentObject var settings: Settings
    @State private var heard = ""
    @State private var written = ""
    @FocusState private var focus: Field?

    private enum Field { case heard, written }

    private var canAdd: Bool {
        !heard.trimmingCharacters(in: .whitespaces).isEmpty && !written.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 8) {
                    TextField("Entendu", text: $heard, prompt: Text("cloud code"))
                        .labelsHidden()
                        .focused($focus, equals: .heard)
                        .onSubmit { focus = .written }
                    Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                    TextField("Écrit", text: $written, prompt: Text("Claude Code"))
                        .labelsHidden()
                        .focused($focus, equals: .written)
                        .onSubmit(add)
                    Button("Ajouter", action: add).disabled(!canAdd)
                }
            } footer: {
                Text("Noms propres, marques, jargon : écrivez ce que Murmure entend, puis ce qu'il doit écrire.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if !settings.replacements.isEmpty {
                Section {
                    ForEach(settings.replacements) { r in
                        HStack(spacing: 8) {
                            Text(r.from).foregroundStyle(.secondary)
                            Image(systemName: "arrow.right").font(.caption).foregroundStyle(.tertiary)
                            Text(r.to.isEmpty ? "(supprimé)" : r.to)
                            Spacer()
                            Button {
                                settings.replacements.removeAll { $0.id == r.id }
                            } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.plain)
                            .help("Supprimer cette correction")
                            .accessibilityLabel("Supprimer \(r.from)")
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func add() {
        guard canAdd else { return }
        settings.replacements.append(WordReplacement(
            from: heard.trimmingCharacters(in: .whitespaces),
            to: written.trimmingCharacters(in: .whitespaces)))
        heard = ""; written = ""
        focus = .heard
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
