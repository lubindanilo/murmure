import SwiftUI

// MARK: - Licence

/// Une phrase, un bouton. La restauration d'un achat reste à un lien discret.
struct LicenseView: View {
    @ObservedObject private var license = LicenseManager.shared
    @State private var transactionID = ""
    @State private var email = ""
    @State private var showRestore = false

    private var isLicensed: Bool {
        if case .licensed = license.state { return true }
        return false
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            Text(title)
                .font(.system(size: 22, weight: .semibold))
                .tracking(-0.3)
                .multilineTextAlignment(.center)
            Text(detail)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)

            if isLicensed {
                Button("Gérer mon abonnement") { license.openCustomerPortal() }
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.voice)
                    .padding(.top, 20)
            } else {
                Button { license.buy() } label: {
                    Text("Acheter Murmure")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(Theme.voice)
                .padding(.top, 24)
            }
            Spacer(minLength: 24)

            if !isLicensed { restore }
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(Theme.quick, value: showRestore)
        .onAppear { license.refresh() }
    }

    @ViewBuilder
    private var restore: some View {
        if showRestore {
            VStack(spacing: 8) {
                TextField("Numéro de transaction (txn_…)", text: $transactionID)
                    .textFieldStyle(.roundedBorder)
                TextField("E-mail d'achat", text: $email)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    if let error = license.lastError {
                        Text(error).font(.system(size: 11)).foregroundStyle(Theme.voice).lineLimit(2)
                    }
                    Spacer()
                    if license.isWorking { ProgressView().controlSize(.small) }
                    Button("Activer") {
                        Task { await license.restore(transactionID: transactionID, email: email) }
                    }
                    .disabled(transactionID.isEmpty || email.isEmpty || license.isWorking)
                }
            }
            .transition(.opacity)
        } else {
            Button("Déjà acheté ?") { showRestore = true }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    private var title: String {
        switch license.state {
        case .licensed: return "Murmure est activé"
        case .trial(let days, _): return days > 1 ? "\(days) jours d'essai restants" : "Dernier jour d'essai"
        case .expired: return "L'essai est terminé"
        }
    }

    private var detail: String {
        switch license.state {
        case .licensed(let expires):
            if let expires { return "Renouvelé le \(expires.formatted(.dateTime.day().month(.wide)))." }
            return "Merci."
        case .trial:
            return "Rien n'est prélevé à la fin de l'essai."
        case .expired:
            return "Vos modes et corrections sont conservés."
        }
    }
}
