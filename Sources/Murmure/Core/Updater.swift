import AppKit
import Foundation

/// Mise à jour sans App Store : la landing publie version.json ; si une version plus récente existe,
/// le menu propose de relancer le script d'installation (téléchargé par curl, donc sans quarantaine).
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()
    static let site = URL(string: "https://murmure-mac.vercel.app")!

    @Published private(set) var available: String?

    func check() {
        Task {
            var req = URLRequest(url: Self.site.appendingPathComponent("version.json"))
            req.cachePolicy = .reloadIgnoringLocalCacheData
            req.timeoutInterval = 10
            guard let (data, _) = try? await URLSession.shared.data(for: req),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let latest = json["version"] as? String else { return }
            if Self.isNewer(latest, than: LicenseManager.appVersion) { available = latest }
        }
        // Puis une fois par jour, l'app restant ouverte longtemps.
        DispatchQueue.main.asyncAfter(deadline: .now() + 86_400) { [weak self] in self?.check() }
    }

    func install() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", "curl -fsSL \(Self.site.absoluteString)/install.sh | MURMURE_UPDATE=1 bash"]
        try? process.run()
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").compactMap { Int($0) }
        let pb = b.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
