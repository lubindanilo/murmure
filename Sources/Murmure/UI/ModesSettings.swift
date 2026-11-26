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
            Section {
                HStack(spacing: 10) {
                    SymbolPicker(symbol: mode.symbol)
                    TextField("Nom", text: mode.name)
                        .textFieldStyle(.plain)
                        .font(.title3.weight(.semibold))
                }
            }

            Section {
                InstructionsEditor(text: mode.instructions)
            } header: {
                Text("Ce que fait ce mode")
            } footer: {
                Text("Par exemple : « Rédige un mail poli et concis ». Laissez vide pour dicter tel quel.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
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

            if !isMain {
                Section {
                    TextField("Mot déclencheur", text: mode.triggerWord, prompt: Text("mail, anglais, prompt…"))
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Apps")
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
                } header: {
                    Text("S'active")
                } footer: {
                    Text("Dites le mot au début de la dictée, ou ouvrez l'une de ces apps. Le mot est retiré du texte.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section {
                DisclosureGroup("Avancé", isExpanded: $showAdvanced) {
                    if !isMain {
                        Picker("Touche dédiée", selection: mode.shortcut) {
                            Text("Aucune").tag(TriggerKey?.none)
                            ForEach(TriggerKey.allCases.filter { $0 != settings.triggerKey }) { key in
                                let usedBy = store.modes.first { $0.shortcut == key && $0.id != modeID }
                                Text(usedBy == nil ? key.label : "\(key.label) (\(usedBy!.name))").tag(TriggerKey?.some(key))
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
                    Picker("Après la dictée", selection: mode.outputMode) {
                        ForEach(OutputMode.allCases) { Text($0.label).tag($0) }
                    }
                    Toggle("Joindre le presse-papiers", isOn: mode.includeClipboard)
                    Toggle("Joindre le nom de l'app active", isOn: mode.includeActiveApp)
                    Toggle("Joindre le texte sélectionné", isOn: mode.includeCursorContext)
                    Toggle("Joindre l'URL de l'onglet actif", isOn: mode.includeBrowserURL)
                    Picker("Corrections appliquées", selection: mode.replacementTiming) {
                        ForEach(ReplacementTiming.allCases) { Text($0.label).tag($0) }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Consigne système (remplace celle de Murmure)").font(.callout)
                        CodeEditor(text: mode.systemPrompt, placeholder: "Laisser vide pour la consigne par défaut", height: 70)
                    }
                    HStack {
                        Text("Température")
                        Slider(value: mode.temperature, in: 0...1, step: 0.1)
                        Text(mode.wrappedValue.temperature.formatted(.number.precision(.fractionLength(1))))
                            .monospacedDigit().foregroundStyle(.secondary).frame(width: 28)
                    }
                    ScriptField(title: "Script avant l'IA", script: mode.scriptBefore, mode: mode.wrappedValue)
                    ScriptField(title: "Script après l'IA", script: mode.scriptAfter, mode: mode.wrappedValue)
                    ModeTester(mode: mode.wrappedValue)
                    Button("Copier le lien murmure://") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("murmure://start?mode_id=\(modeID.uuidString)", forType: .string)
                    }
                    .buttonStyle(.link)
                }
            }

            if !isMain {
                Section {
                    if confirmDelete {
                        HStack {
                            Text("Supprimer « \(mode.wrappedValue.name) » ?")
                            Spacer()
                            Button("Annuler") { confirmDelete = false }
                            Button("Supprimer", role: .destructive) {
                                store.delete(mode.wrappedValue)
                                dismiss()
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    } else {
                        Button("Supprimer le mode", role: .destructive) { confirmDelete = true }
                            .buttonStyle(.link)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .subpage(title: mode.wrappedValue.name, back: "Murmure") { dismiss() }
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
        VStack(alignment: .leading, spacing: 6) {
            CodeEditor(text: $text, placeholder: "Par exemple : transforme la dictée en e-mail professionnel.", height: 110, monospaced: false)
            HStack(spacing: 6) {
                Text("Insérer").font(.caption).foregroundStyle(.secondary)
                ForEach(["CONTEXT.SELECTED_TEXT", "CONTEXT.CLIPBOARD", "CONTEXT.APP", "CONTEXT.URL"], id: \.self) { key in
                    Button(key.replacingOccurrences(of: "CONTEXT.", with: "").lowercased()) {
                        text += (text.isEmpty || text.hasSuffix(" ") ? "" : " ") + "{{\(key)}}"
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .help("{{\(key)}}")
                }
            }
        }
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
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Theme.voice)
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.voiceSoft))
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

struct ScriptField: View {
    let title: String
    @Binding var script: String
    let mode: Mode
    @State private var result: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.callout)
                Spacer()
                if !script.isEmpty {
                    Button("Tester le script") { Task { await test() } }.controlSize(.small)
                }
            }
            CodeEditor(text: $script, placeholder: "# zsh : le texte arrive sur stdin\ntr '[:lower:]' '[:upper:]'", height: 70)
            if let result {
                Text(result).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
    }

    private func test() async {
        var ctx = DictationContext()
        ctx.appName = "Notes"; ctx.appBundleID = "com.apple.Notes"; ctx.clipboard = "texte du presse-papiers"
        ctx.selectedText = "texte sélectionné"; ctx.browserURL = "https://example.com"
        do {
            let r = try await ScriptRunner.run(script, input: "Ceci est une dictée d'essai.", context: ctx, mode: mode,
                                               audioDuration: 42, audioFile: nil)
            var lines = ["Sortie : \(r.output.isEmpty ? "(vide : rien ne sera inséré)" : r.output)"]
            if r.skipAI { lines.append("skip_ai=1 : l'IA sera sautée") }
            if let o = r.outputMode { lines.append("Sortie forcée : \(o.label)") }
            if let s = r.switchMode { lines.append("Bascule vers le mode \(s)") }
            result = lines.joined(separator: "\n")
        } catch {
            result = error.localizedDescription
        }
    }
}

/// Fait passer un texte d'essai par l'IA et la traduction du mode, sans dicter.
struct ModeTester: View {
    let mode: Mode
    @EnvironmentObject var settings: Settings
    @State private var input = "euh donc je voulais dire que la réunion de demain est décalée à 15h parce que Louis peut pas le matin"
    @State private var output: String?
    @State private var running = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Texte dicté", text: $input, axis: .vertical)
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
