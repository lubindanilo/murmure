import AppKit
import CryptoKit
import Foundation
import IOKit

/// Essai gratuit de 14 jours puis abonnement payant (Paddle, 9,99 € par mois).
///
/// Le serveur de licences enregistre la date de première ouverture de chaque Mac
/// (une réinstallation ne relance pas l'essai) et signe un jeton Ed25519 que l'app vérifie
/// avec la clé publique ci-dessous. Hors ligne, le dernier jeton valide fait foi.
@MainActor
final class LicenseManager: ObservableObject {
    static let shared = LicenseManager()

    static let trialDays = 14
    /// Clé publique Ed25519 du serveur (base64, 32 octets). La clé privée ne vit que sur le serveur.
    static let publicKey = "UO9AMUGsHz7myfveHliePomBEKowpyo6s7+UcIPubbE="
    static var server: URL {
        URL(string: UserDefaults.standard.string(forKey: "licenseServer") ?? "https://ramage-ai.com/api")!
    }

    enum State: Equatable {
        case trial(daysLeft: Int, endsAt: Date)
        case licensed(expiresAt: Date?)
        case expired
    }

    struct Token: Codable {
        let device: String
        let plan: String          // "trial" ou "pro"
        let trialEndsAt: Date?
        let expiresAt: Date?      // nil : licence à vie
        let issuedAt: Date
        let email: String?
    }

    @Published private(set) var state: State = .trial(daysLeft: LicenseManager.trialDays, endsAt: .distantFuture)
    @Published private(set) var token: Token?
    @Published private(set) var lastError: String?
    @Published private(set) var isWorking = false
    @Published private(set) var secondsToday: TimeInterval = 0

    let deviceID: String = LicenseManager.makeDeviceID()
    private var pollTask: Task<Void, Never>?

    private init() {
        if Keychain.get("trialStart") == nil {
            Keychain.set(ISO8601DateFormatter().string(from: Date()), for: "trialStart")
        }
        token = loadToken()
        recompute()
        secondsToday = usage[Self.today] ?? 0
    }

    var canDictate: Bool {
        if case .expired = state { return false }
        return true
    }

    var localTrialStart: Date {
        Keychain.get("trialStart").flatMap { ISO8601DateFormatter().date(from: $0) } ?? Date()
    }

    // MARK: Serveur

    /// Récupère le statut signé du Mac auprès du serveur (au lancement, puis une fois par jour).
    func refresh() {
        Task {
            do {
                let json = try await post("/v1/device", ["device_id": deviceID, "app_version": Self.appVersion,
                                                         "trial_start": ISO8601DateFormatter().string(from: localTrialStart)])
                try accept(json)
                lastError = nil
            } catch {
                lastError = nil // hors ligne : on garde le dernier jeton, sans alarmer l'utilisateur
            }
        }
    }

    /// Ouvre le paiement Paddle pour ce Mac, puis surveille l'activation pendant 15 minutes.
    func buy() {
        var comps = URLComponents(url: Self.server.appendingPathComponent("buy"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "device", value: deviceID)]
        if let url = comps.url { NSWorkspace.shared.open(url) }
        pollTask?.cancel()
        pollTask = Task {
            for _ in 0..<180 {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                if Task.isCancelled { return }
                refresh()
                if case .licensed = state { return }
            }
        }
    }

    /// Rattache ce Mac à un achat existant (numéro de transaction du reçu Paddle).
    func restore(transactionID: String, email: String) async {
        isWorking = true
        defer { isWorking = false }
        do {
            let json = try await post("/v1/restore", ["device_id": deviceID, "transaction_id": transactionID,
                                                      "email": email])
            try accept(json)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func openCustomerPortal() {
        var comps = URLComponents(url: Self.server.appendingPathComponent("account"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "device", value: deviceID)]
        if let url = comps.url { NSWorkspace.shared.open(url) }
    }

    private func post(_ path: String, _ body: [String: String]) async throws -> [String: Any] {
        var req = URLRequest(url: Self.server.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.timeoutInterval = 10
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(code) else {
            throw MurmureError.unsupported(json["error"] as? String ?? "Le serveur de licences a répondu \(code).")
        }
        return json
    }

    /// Vérifie la signature du jeton renvoyé par le serveur avant de l'enregistrer.
    private func accept(_ json: [String: Any]) throws {
        guard let payload = json["token"] as? String, let signature = json["signature"] as? String,
              let token = Self.verify(payload: payload, signature: signature), token.device == deviceID else {
            throw MurmureError.unsupported("Réponse du serveur de licences invalide.")
        }
        Keychain.set(payload + "." + signature, for: "licenseToken")
        self.token = token
        recompute()
    }

    private func loadToken() -> Token? {
        guard let stored = Keychain.get("licenseToken") else { return nil }
        let parts = stored.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2, let token = Self.verify(payload: parts[0], signature: parts[1]),
              token.device == deviceID else { return nil }
        return token
    }

    static func verify(payload: String, signature: String) -> Token? {
        guard let keyData = Data(base64Encoded: publicKey),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
              let payloadData = Data(base64URL: payload), let sig = Data(base64URL: signature),
              key.isValidSignature(sig, for: Data(payload.utf8)) else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Token.self, from: payloadData)
    }

    private func recompute() {
        let now = Date()
        if let token, token.plan == "pro" {
            // 3 jours de marge si l'abonnement n'a pas pu être revérifié (hors ligne).
            if let expires = token.expiresAt, now > expires.addingTimeInterval(3 * 86_400) {
                state = .expired
            } else {
                state = .licensed(expiresAt: token.expiresAt)
            }
            return
        }
        // Essai : la date la plus ancienne entre le serveur et ce Mac.
        let localEnd = localTrialStart.addingTimeInterval(Double(Self.trialDays) * 86_400)
        let end = min(token?.trialEndsAt ?? localEnd, localEnd)
        if now >= end {
            state = .expired
        } else {
            let days = Int(ceil(end.timeIntervalSince(now) / 86_400))
            state = .trial(daysLeft: max(1, days), endsAt: end)
        }
    }

    // MARK: Utilisation (statistiques locales)

    private static var today: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    private var usage: [String: TimeInterval] {
        get { (UserDefaults.standard.dictionary(forKey: "usage") as? [String: TimeInterval]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "usage") }
    }

    func recordUsage(seconds: TimeInterval) {
        var u = usage
        u[Self.today, default: 0] += seconds
        usage = u
        secondsToday = u[Self.today] ?? 0
        recompute()
    }

    // MARK: Identité du Mac

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    /// Identifiant stable et anonyme : empreinte de l'UUID matériel, jamais l'UUID lui-même.
    private static func makeDeviceID() -> String {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        defer { IOObjectRelease(service) }
        let uuid = (IORegistryEntryCreateCFProperty(service, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String) ?? UUID().uuidString
        let digest = SHA256.hash(data: Data(("murmure:" + uuid).utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}

extension Data {
    init?(base64URL: String) {
        var s = base64URL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        self.init(base64Encoded: s)
    }
}
