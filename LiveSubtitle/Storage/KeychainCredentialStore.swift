import Foundation
import Security

actor KeychainCredentialStore: CredentialStoring {
    nonisolated let service: String

    init(service: String = "com.zhshy7713950.LiveSubtitle.credentials") {
        self.service = service
    }

    func readKey(profileID: UUID) async throws -> String? {
        var query = baseQuery(profileID: profileID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw StorageError.credentialReadFailed }
        guard let data = result as? Data, let key = String(data: data, encoding: .utf8) else {
            throw StorageError.invalidCredentialData
        }
        return key
    }

    func replaceKey(_ key: String, profileID: UUID) async throws {
        let data = Data(key.utf8)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let status = SecItemUpdate(baseQuery(profileID: profileID) as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return }
        if status == errSecItemNotFound {
            var query = baseQuery(profileID: profileID)
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            query[kSecAttrSynchronizable as String] = false
            guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else {
                throw StorageError.credentialWriteFailed
            }
            return
        }
        throw StorageError.credentialWriteFailed
    }

    func deleteKey(profileID: UUID) async throws {
        let status = SecItemDelete(baseQuery(profileID: profileID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw StorageError.credentialWriteFailed
        }
    }

    func clearAppNamespace() async throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw StorageError.credentialWriteFailed
        }
    }

    private func baseQuery(profileID: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profileID.uuidString
        ]
    }
}
