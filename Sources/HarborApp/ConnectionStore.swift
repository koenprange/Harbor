import Foundation
import Security

struct LocalCredentials: Codable {
    let username: String
    let password: String
}

enum ConnectionStore {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "nl.koenprange.harbor.transmission",
         kSecAttrAccount as String: "local-rpc"]
    }
    static func load() throws -> LocalCredentials? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw StoreError(status: status) }
        return try JSONDecoder().decode(LocalCredentials.self, from: data)
    }
    static func save(_ credentials: LocalCredentials) throws {
        let data = try JSONEncoder().encode(credentials)
        let attributes = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw StoreError(status: status) }
    }
    private struct StoreError: LocalizedError {
        let status: OSStatus
        var errorDescription: String? { "Could not access the macOS Keychain (\(status))." }
    }
}
