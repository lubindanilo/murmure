import SwiftUI

// MARK: - Licence

struct LicenseView: View {
    @ObservedObject private var license = LicenseManager.shared
    @State private var transactionID = ""
    @State private var email = ""
    @State private var showRestore = false

    var body: some View {
        Form {
            Section {
                VStack(spacing: 14) {
                    SettingsIcon(symbol: icon, color: iconColor, size: 56)
                    VStack(spacing: 4) {
                        Text(title).font(.system(size: 17, weight: .semibold))
                        Text(detail)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if case .trial(let days, _) = license.state {
                        TrialMeter(daysLeft: days)
                    }
                    switch license.state {
                    case .licensed:
                        Button("Gérer mon abonnement") { license.openCustomerPortal() }
                            .controlSize(.large)
                    default:
                        Button { license.buy() } label: {
                            Text("Acheter Murmure").font(.system(size: 13, weight: .semibold)).frame(minWidth: 160)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            }

            if case .licensed = license.state {} else {
                Section {
                    if showRestore {
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
                    } else {
                        Button("Déjà acheté ? Restaurer un achat") { showRestore = true }
                            .buttonStyle(.link)
                            .frame(maxWidth: .infinity)
                    }
                } footer: {
                    if showRestore {
                        Text("Le numéro de transaction figure dans le reçu envoyé par Paddle après l'achat.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { license.refresh() }
    }

    private var icon: String {
        switch license.state {
        case .licensed: return "checkmark.seal.fill"
        case .trial: return "hourglass"
        case .expired: return "lock.fill"
        }
    }

    private var iconColor: Color {
        switch license.state {
        case .licensed: return .green
        case .trial: return Theme.voice
        case .expired: return Color(white: 0.55)
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
            return "Tout est ouvert jusqu'au \(end.formatted(.dateTime.day().month(.wide))). Rien n'est prélevé à la fin."
        case .expired:
            return "Vos réglages, modes et historique sont conservés. Activez Murmure pour reprendre la dictée."
        }
    }

    static func minutes(_ seconds: TimeInterval) -> String {
        let m = Int(seconds) / 60, s = Int(seconds) % 60
        return m > 0 ? "\(m) min \(s) s" : "\(s) s"
    }
}

/// Sept segments : les jours d'essai qui restent.
struct TrialMeter: View {
    let daysLeft: Int

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<7, id: \.self) { i in
                Capsule()
                    .fill(i < 7 - daysLeft ? Color.primary.opacity(0.12) : Theme.voice)
                    .frame(width: 28, height: 4)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("\(daysLeft) jours d'essai restants sur 7")
    }
}
