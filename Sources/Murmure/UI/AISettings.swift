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
            PanelSubpageBar(title: "Licence", back: { PanelController.shared.router.path.removeAll() }) { EmptyView() }
            VStack(spacing: 14) {
                BarsGlyph(height: 22, color: Theme.voice)
                    .frame(width: 52, height: 48)
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Theme.voice.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                    .padding(.top, 8)
                VStack(spacing: 4) {
                    Text(title).font(.system(size: 17, weight: .semibold))
                    if !detail.isEmpty {
                        Text(detail).font(.system(size: 12)).foregroundStyle(Palette.muted)
                            .multilineTextAlignment(.center)
                    }
                }
                if isLicensed {
                    Button("Gérer mon abonnement") { license.openCustomerPortal() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.voice)
                } else {
                    Button("Acheter Murmure") { license.buy() }
                        .buttonStyle(AccentButtonStyle())
                    restore
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
        }
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
                .foregroundStyle(Theme.voice)
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
            return ""
        case .expired:
            return "Vos corrections et votre historique sont conservés."
        }
    }
}
