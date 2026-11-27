import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Éditeur

struct ModeEditor: View {
    let modeID: UUID
    @ObservedObject private var store = ModeStore.shared
    @EnvironmentObject var settings: Settings
    @Environment(\.dismiss) private var dismiss
    @State private var newWebsite = ""
    @State private var showAdvanced = false
    @State private var confirmDelete = false

    private var binding: Binding<Mode> {
        Binding(get: { store.mode(modeID) ?? Mode.main() }, set: { store.update($0) })
    }

    var body: some View {
        let mode = binding
        let isMain = mode.wrappedValue.isMain
        Form {
            if !isMain {
                Section {
                    LabeledContent("Touche") {
                        KeyCap(label: mode.wrappedValue.shortcut?.capLabel ?? "Aucune touche",
                               muted: mode.wrappedValue.shortcut == nil) { KeyMenu(modeID: modeID) }
                    }
                    Picker("Traduire vers", selection: mode.translateTo) {
                        Text("Ne pas traduire").tag(String?.none)
                        ForEach(Languages.all.filter { $0.code != "auto" }, id: \.code) { lang in
                            Text(lang.name).tag(String?.some(lang.code))
                        }
                    }
                    if let target = mode.wrappedValue.translateTo {
                        TranslationDownloadButton(source: settings.language, target: target)
                    }
                }
            }

            Section("Ce que fait ce mode") {
                InstructionsEditor(text: mode.instructions)
            }

            if !isMain {
                Section("Essayer") {
                    ModeTester(mode: mode.wrappedValue)
                }
            }

            // Toute la ligne ouvre et ferme la section, pas seulement le chevron.
            Section {
                Button { withAnimation(Theme.quick) { showAdvanced.toggle() } } label: {
                    HStack {
                        Text("Avancé")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(showAdvanced ? 90 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(showAdvanced ? "Ouvert" : "Fermé")
                if showAdvanced && !isMain {
                    TextField("Mot déclencheur", text: mode.triggerWord, prompt: Text("mail, anglais, prompt…"))
                        .help("Dit au début de la dictée, il active ce mode et est retiré du texte.")
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("S'active aussi dans")
                            Spacer()
                            AppPickerButton { app in
                                if !mode.wrappedValue.apps.contains(app) { mode.wrappedValue.apps.append(app) }
                            }
                        }
                        if !mode.wrappedValue.apps.isEmpty {
                            WrapLayout(spacing: 6) {
                                ForEach(mode.wrappedValue.apps) { app in
                                    Chip(text: app.name) { mode.wrappedValue.apps.removeAll { $0 == app } }
                                }
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            TextField("Sites", text: $newWebsite, prompt: Text("mail.google.com"))
                                .onSubmit { addWebsite(mode) }
                            Button("Ajouter") { addWebsite(mode) }.disabled(newWebsite.isEmpty)
                        }
                        if !mode.wrappedValue.websites.isEmpty {
                            WrapLayout(spacing: 6) {
                                ForEach(mode.wrappedValue.websites, id: \.self) { site in
                                    Chip(text: site) { mode.wrappedValue.websites.removeAll { $0 == site } }
                                }
                            }
                        }
                    }
                }
            } footer: {
                if !isMain { deleteControl(mode.wrappedValue) }
            }
        }
        .formStyle(.grouped)
        // Le nom et l'icône se modifient dans la barre du haut : pas de doublon dans la page.
        .subpage(back: "", action: { PanelController.shared.router.path.removeAll() }) {
            HStack(spacing: 6) {
                SymbolPicker(symbol: mode.symbol, size: 22)
                TextField("Nom", text: mode.name, prompt: Text("Nom du mode"))
                    .labelsHidden()
                    .textFieldStyle(.plain)
                    .fixedSize()
                    .accessibilityLabel("Nom du mode")
            }
        }
    }

    /// Petite poubelle en bas de page ; un premier clic demande confirmation sur place.
    @ViewBuilder
    private func deleteControl(_ mode: Mode) -> some View {
        HStack(spacing: 10) {
            Spacer()
            if confirmDelete {
                Text("Supprimer « \(mode.name) » ?").foregroundStyle(.secondary)
                Button("Annuler") { confirmDelete = false }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                Button("Supprimer") {
                    store.delete(mode)
                    PanelController.shared.router.path.removeAll()
                }
                .buttonStyle(.plain).foregroundStyle(Theme.warn).fontWeight(.semibold)
            } else {
                Button { confirmDelete = true } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .help("Supprimer le mode")
                .accessibilityLabel("Supprimer le mode")
            }
        }
        .font(.system(size: 12))
        .padding(.top, 8)
    }

    private func addWebsite(_ mode: Binding<Mode>) {
        let site = newWebsite.trimmingCharacters(in: .whitespaces).lowercased()
            .replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "")
            .split(separator: "/").first.map(String.init) ?? ""
        guard !site.isEmpty, !mode.wrappedValue.websites.contains(site) else { return }
        mode.wrappedValue.websites.append(site)
        newWebsite = ""
    }
}

// MARK: - Composants

struct InstructionsEditor: View {
    @Binding var text: String

    var body: some View {
        CodeEditor(text: $text, placeholder: "Laissez vide pour dicter tel quel.", height: 110, monospaced: false)
    }
}

struct CodeEditor: View {
    @Binding var text: String
    var placeholder: String
    var height: CGFloat
    var monospaced = true

    var body: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $text)
                .font(monospaced ? .system(.callout, design: .monospaced) : .body)
                .scrollContentBackground(.hidden)
                .padding(5)
            if text.isEmpty {
                Text(placeholder)
                    .font(monospaced ? .system(.callout, design: .monospaced) : .body)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .allowsHitTesting(false)
            }
        }
        .frame(height: height)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.25)))
    }
}

struct Chip: View {
    let text: String
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(text).font(.callout)
            Button(action: remove) { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Retirer \(text)")
        }
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(Capsule().fill(Color.primary.opacity(0.07)))
    }
}

struct SymbolPicker: View {
    @Binding var symbol: String
    var size: CGFloat = 32
    static let symbols = ["waveform", "text.bubble", "envelope", "bubble.left.and.bubble.right", "globe", "sparkles",
                          "doc.text", "checklist", "arrowshape.turn.up.left", "textformat", "terminal",
                          "magnifyingglass", "briefcase", "heart", "bolt", "list.bullet"]

    var body: some View {
        Menu {
            ForEach(Self.symbols, id: \.self) { s in
                Button { symbol = s } label: { Label(s, systemImage: s) }
            }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: size / 2, weight: .medium))
                .foregroundStyle(Theme.voice)
                .frame(width: size, height: size)
                .background(RoundedRectangle(cornerRadius: size / 4, style: .continuous).fill(Theme.voiceSoft))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Changer l'icône")
    }
}

/// Choix d'une app : apps ouvertes, ou n'importe quelle app du dossier Applications.
struct AppPickerButton: View {
    let pick: (AppRef) -> Void

    var body: some View {
        Menu("Ajouter une app") {
            ForEach(runningApps, id: \.bundleID) { app in
                Button(app.name) { pick(app) }
            }
            Divider()
            Button("Autre app…") { chooseFile() }
        }
        .fixedSize()
    }

    private var runningApps: [AppRef] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .compactMap { app in app.bundleIdentifier.map { AppRef(bundleID: $0, name: app.localizedName ?? $0) } }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url, let bundle = Bundle(url: url),
              let id = bundle.bundleIdentifier else { return }
        let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        pick(AppRef(bundleID: id, name: name))
    }
}

/// Fait passer un texte d'essai par l'IA et la traduction du mode, sans dicter.
struct ModeTester: View {
    let mode: Mode
    @EnvironmentObject var settings: Settings
    @State private var input = "salut Thomas euh la réunion de jeudi est décalée à vendredi 10h parce que Louis peut pas dis-moi si ça te va"
    @State private var output: String?
    @State private var running = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Texte dicté", text: $input, prompt: Text("Ce que vous diriez"), axis: .vertical)
                .labelsHidden()
                .lineLimit(2...4)
            HStack {
                Button(running ? "Traitement…" : "Tester") { Task { await run() } }
                    .disabled(running || input.isEmpty)
                if running { ProgressView().controlSize(.small) }
            }
            if let output {
                Text(output)
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
            }
        }
    }

    private func run() async {
        running = true
        defer { running = false }
        var text = input
        do {
            if settings.aiEnabled, mode.usesAI {
                text = try await PostProcessor.shared.process(text, mode: mode, context: DictationContext.capture(),
                                                               settings: settings)
            }
            if let target = mode.translateTo {
                text = try await Translator.shared.translate(text, from: settings.language, to: target)
            }
            output = text
        } catch {
            output = error.localizedDescription
        }
    }
}
