import SwiftUI

struct AISettings: View {
    @EnvironmentObject var settings: Settings
    @ObservedObject private var ai = PostProcessor.shared

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $settings.aiEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("IA locale")
                        Text("Le nettoyage et les instructions des modes passent par un modèle de langage qui tourne sur ce Mac. Aucun texte n'est envoyé, aucun coût de tokens.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .onChange(of: settings.aiEnabled) { _, on in if on { Setup.shared.install() } else { ai.unload() } }
            }

            if settings.aiEnabled {
                Section("Moteur") {
                    Picker("Exécuter avec", selection: $settings.aiBackend) {
                        ForEach(AIBackend.allCases) { Text($0.label).tag($0) }
                    }
                    .onChange(of: settings.aiBackend) { _, backend in
                        settings.aiServerURL = ""
                        if backend == .embedded { Setup.shared.install() } else {
                            Task { await ai.refreshServerModels(settings: settings) }
                        }
                    }

                    if settings.aiBackend == .embedded {
                        ForEach(LocalLLM.all) { llm in
                            LLMRow(llm: llm, selected: settings.aiLocalModelID == llm.id,
                                   recommended: llm.id == Setup.defaultLLM) {
                                settings.aiLocalModelID = llm.id
                                ai.warmUp(settings: settings)
                            }
                        }
                        if let error = ai.lastError {
                            Text(error).font(.caption).foregroundStyle(Theme.voice)
                        }
                    } else {
                        serverSettings
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task {
            if settings.aiBackend != .embedded { await ai.refreshServerModels(settings: settings) }
        }
    }

    @ViewBuilder
    private var serverSettings: some View {
        TextField("Adresse du serveur", text: $settings.aiServerURL, prompt: Text(settings.aiBackend.defaultBaseURL))
        HStack {
            Picker("Modèle", selection: $settings.aiServerModel) {
                Text("Choisir…").tag("")
                ForEach(ai.serverModels, id: \.self) { Text($0).tag($0) }
            }
            Button {
                Task { await ai.refreshServerModels(settings: settings) }
            } label: { Image(systemName: "arrow.clockwise") }
                .help("Actualiser la liste des modèles")
        }
        if let error = ai.serverError {
            Text(error).font(.caption).foregroundStyle(Theme.voice)
        }
        Text(settings.aiBackend == .ollama
             ? "Installez Ollama (ollama.com), puis par exemple : ollama pull qwen2.5:3b"
             : "Dans LM Studio, chargez un modèle puis démarrez le serveur local (onglet Developer).")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

struct LLMRow: View {
    let llm: LocalLLM
    let selected: Bool
    let recommended: Bool
    let select: () -> Void
    @ObservedObject private var ai = PostProcessor.shared

    var body: some View {
        let installed = ai.installed.contains(llm.id)
        HStack(spacing: 12) {
            SelectionMark(selected: selected, enabled: installed)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(llm.name).fontWeight(selected ? .semibold : .regular)
                    if recommended { Text("par défaut").font(.caption).foregroundStyle(.secondary) }
                }
                Text("\(llm.sizeLabel) · \(llm.note)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Group {
                if let progress = ai.downloadProgress[llm.id] {
                    HStack(spacing: 6) {
                        ProgressView(value: progress).frame(width: 70)
                        Button { ai.cancelDownload(llm) } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                            .help("Annuler le téléchargement")
                    }
                } else if !installed {
                    Button("Télécharger") { ai.download(llm) }.controlSize(.small)
                } else if selected {
                    Text("Utilisé").font(.caption).foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 6) {
                        Button("Utiliser", action: select).controlSize(.small)
                        Button { ai.delete(llm) } label: { Image(systemName: "trash") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                            .help("Supprimer le modèle du disque")
                    }
                }
            }
            .frame(width: 118, alignment: .trailing)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture { if installed { select() } }
    }
}

// MARK: - Licence

struct LicenseView: View {
    @ObservedObject private var license = LicenseManager.shared
    @State private var transactionID = ""
    @State private var email = ""

    var body: some View {
        Form {
            Section {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: icon)
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(Theme.voice)
                        .frame(width: 40, height: 40)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.voiceSoft))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title).font(.headline)
                        Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                }
                .padding(.vertical, 4)

                switch license.state {
                case .licensed:
                    Button("Gérer mon abonnement") { license.openCustomerPortal() }
                default:
                    Button("Acheter Murmure") { license.buy() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                }
            }

            if case .licensed = license.state {} else {
                Section {
                    TextField("Numéro de transaction", text: $transactionID, prompt: Text("txn_…"))
                    TextField("E-mail d'achat", text: $email, prompt: Text("vous@exemple.fr"))
                    HStack {
                        Button("Activer sur ce Mac") {
                            Task { await license.restore(transactionID: transactionID, email: email) }
                        }
                        .disabled(transactionID.isEmpty || email.isEmpty || license.isWorking)
                        if license.isWorking { ProgressView().controlSize(.small) }
                    }
                    if let error = license.lastError {
                        Text(error).font(.caption).foregroundStyle(Theme.voice)
                    }
                } header: {
                    Text("Déjà acheté ?")
                } footer: {
                    Text("Le numéro de transaction figure dans le reçu envoyé par Paddle après l'achat.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Aujourd'hui") {
                LabeledContent("Temps dicté", value: Self.minutes(license.secondsToday))
                LabeledContent("Identifiant de ce Mac", value: license.deviceID)
                    .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .onAppear { license.refresh() }
    }

    private var icon: String {
        switch license.state {
        case .licensed: return "checkmark.seal"
        case .trial: return "hourglass"
        case .expired: return "lock"
        }
    }

    private var title: String {
        switch license.state {
        case .licensed: return "Murmure est activé"
        case .trial(let days, _): return days > 1 ? "Essai gratuit : \(days) jours restants" : "Essai gratuit : dernier jour"
        case .expired: return "Essai terminé"
        }
    }

    private var detail: String {
        switch license.state {
        case .licensed(let expires):
            if let expires { return "Abonnement actif jusqu'au \(expires.formatted(date: .long, time: .omitted)), renouvelé automatiquement." }
            return "Licence à vie sur ce Mac. Merci !"
        case .trial(_, let end):
            return "Toutes les fonctions sont ouvertes jusqu'au \(end.formatted(date: .long, time: .shortened))."
        case .expired:
            return "Vos réglages, modes et historique sont conservés. Activez Murmure pour reprendre la dictée."
        }
    }

    static func minutes(_ seconds: TimeInterval) -> String {
        let m = Int(seconds) / 60, s = Int(seconds) % 60
        return m > 0 ? "\(m) min \(s) s" : "\(s) s"
    }
}
