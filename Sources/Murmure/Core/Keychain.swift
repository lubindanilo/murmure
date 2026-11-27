import Foundation
import Security

/// Clés API stockées dans le trousseau macOS, jamais dans les préférences.
enum Keychain {
    private static let service = "app.murmure.api-keys"

    /// Les bancs en ligne de commande (binaire non signé) ne touchent pas au trousseau : macOS y
    /// bloquerait le test derrière une demande d'autorisation. Ils n'utilisent que des modèles locaux.
    private static let disabled = CommandLine.arguments.contains { ["--selftest", "--llmtest", "--cleanuptest", "--guardtest"].contains($0) }

    static func get(_ account: String) -> String? {
        guard !disabled else { return nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        let value = String(data: data, encoding: .utf8)
        return value?.isEmpty == true ? nil : value
    }

    static func set(_ value: String?, for account: String) {
        guard !disabled else { return }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func apiKey(_ provider: CloudProvider) -> String? { get(provider.rawValue) }
    static func setAPIKey(_ key: String?, _ provider: CloudProvider) { set(key, for: provider.rawValue) }
}
