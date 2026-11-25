import SwiftUI

struct DictionarySettings: View {
    @EnvironmentObject var settings: Settings
    @State private var newWord = ""
    @State private var newFrom = ""
    @State private var newTo = ""

    var body: some View {
        Form {
            Section {
                HStack {
                    TextField("Ajouter un mot", text: $newWord, prompt: Text("Hyperstack, Mibba, Dauphine…"))
                        .onSubmit(addWord)
                    Button("Ajouter", action: addWord).disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if settings.dictionary.isEmpty {
                    Text("Noms propres, marques, jargon : écrits ici, ils seront orthographiés comme vous le voulez.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    FlowWords(words: settings.dictionary) { word in
                        settings.dictionary.removeAll { $0 == word }
                    }
                }
            } header: {
                Text("Mots personnels")
            } footer: {
                Text("L'IA locale reprend leur orthographe exacte. Pour un mot toujours mal entendu, ajoutez plutôt un remplacement.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    TextField("Entendu", text: $newFrom, prompt: Text("cloud code"))
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    TextField("Écrit", text: $newTo, prompt: Text("Claude Code"))
                    Button("Ajouter", action: addReplacement).disabled(newFrom.isEmpty)
                }
                ForEach($settings.replacements) { $r in
                    HStack {
                        Text(r.from)
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        Text(r.to.isEmpty ? "(supprimé)" : r.to)
                        Spacer()
                        Toggle("Respecter la casse", isOn: $r.caseSensitive)
                            .toggleStyle(.checkbox)
                            .font(.caption)
                        Button {
                            settings.replacements.removeAll { $0.id == r.id }
                        } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .help("Supprimer ce remplacement")
                    }
                }
            } header: {
                Text("Remplacements")
            } footer: {
                Text("Appliqués à chaque dictée, mot entier, avant et après l'IA.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func addWord() {
        let w = newWord.trimmingCharacters(in: .whitespaces)
        guard !w.isEmpty, !settings.dictionary.contains(w) else { return }
        settings.dictionary.append(w)
        newWord = ""
    }

    private func addReplacement() {
        settings.replacements.append(WordReplacement(from: newFrom, to: newTo))
        newFrom = ""; newTo = ""
    }
}

/// Mots du dictionnaire en jetons supprimables, sur plusieurs lignes.
struct FlowWords: View {
    let words: [String]
    let remove: (String) -> Void

    var body: some View {
        WrapLayout(spacing: 6) {
            ForEach(words, id: \.self) { word in
                HStack(spacing: 4) {
                    Text(word)
                    Button { remove(word) } label: {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Retirer \(word)")
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.primary.opacity(0.07)))
            }
        }
        .padding(.vertical, 2)
    }
}

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

// MARK: - Historique

struct HistoryView: View {
    @EnvironmentObject var settings: Settings
    @ObservedObject private var store = HistoryStore.shared
    @State private var query = ""
    @State private var confirmClear = false

    private var filtered: [HistoryEntry] {
        guard !query.isEmpty else { return store.entries }
        return store.entries.filter { $0.text.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        Group {
            if store.entries.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "waveform").font(.system(size: 28)).foregroundStyle(.tertiary)
                    Text("Aucune dictée pour l'instant").font(.headline)
                    Text("Maintenez \(settings.triggerKey.label) et parlez : vos dictées apparaîtront ici.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(filtered) { entry in
                        HistoryRow(entry: entry)
                            .contextMenu {
                                Button("Copier") { copy(entry.text) }
                                if let raw = entry.rawText { Button("Copier la transcription brute") { copy(raw) } }
                                Divider()
                                Button("Supprimer", role: .destructive) { store.delete(entry) }
                            }
                    }
                }
                .searchable(text: $query, placement: .toolbar, prompt: "Rechercher")
                .overlay {
                    if filtered.isEmpty { Text("Aucun résultat").foregroundStyle(.secondary) }
                }
            }
        }
        .toolbar {
            if !store.entries.isEmpty {
                Button("Tout effacer") { confirmClear = true }
            }
        }
        .confirmationDialog("Effacer tout l'historique ?", isPresented: $confirmClear) {
            Button("Effacer \(store.entries.count) dictées", role: .destructive) { store.clear() }
        } message: {
            Text("Les dictées sont supprimées de ce Mac. Cette action est définitive.")
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

struct HistoryRow: View {
    let entry: HistoryEntry
    @State private var showRaw = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(entry.date, format: .dateTime.day().month().hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text([entry.modelName, entry.modeName].compactMap { $0 }.joined(separator: " + "))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                Text(String(format: "%.1f s → %.1f s", entry.duration, entry.processingTime))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .help("Durée de la dictée, puis temps de traitement")
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(entry.text, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Copier")
            }
            Text(showRaw ? (entry.rawText ?? entry.text) : entry.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if entry.rawText != nil {
                Button(showRaw ? "Voir le texte final" : "Voir la transcription brute") { showRaw.toggle() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
        .padding(.vertical, 4)
    }
}
