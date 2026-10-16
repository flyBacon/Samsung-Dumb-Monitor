// SPDX-License-Identifier: MPL-2.0
import Foundation
import Security

public struct S9Credentials: Codable, Sendable {
    public var host: String
    public let token: String
    public let certificateSHA256: String

    public init(host: String, token: String, certificateSHA256: String) {
        self.host = host
        self.token = token
        self.certificateSHA256 = certificateSHA256
    }
}

/// Shared by the menu bar app and CLI. No credentials belong in the repository.
public enum S9CredentialStore {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "local.dumb-monitor.app.lan-controller",
         kSecAttrAccount as String: "samsung-s9"]
    }

    public static func load() throws -> S9Credentials? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw StoreError(status: status) }
        return try JSONDecoder().decode(S9Credentials.self, from: data)
    }

    public static func save(_ value: S9Credentials) throws {
        let data = try JSONEncoder().encode(value)
        let update = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var request = query
            request[kSecValueData as String] = data
            request[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(request as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw StoreError(status: status) }
    }

    /// Removes only this app/CLI's shared local controller credential.
    public static func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw StoreError(status: status) }
    }

    private struct StoreError: LocalizedError {
        let status: OSStatus
        var errorDescription: String? {
            String(format: NSLocalizedString("Keychain access failed (%d).", bundle: .main, comment: ""), status)
        }
    }
}
