import Foundation
import Security
import TTMCore

/// SecretStore backed by the iOS/macOS Keychain. Stores the SimpleFIN Access URL
/// device-side; it is never written to the app DB and never sent to any backend.
public struct KeychainSecretStore: SecretStore {
    private let service: String

    public init(service: String = "money.trackthe.simplefin") {
        self.service = service
    }

    public func read(ref: String) throws -> String? {
        var query = baseQuery(ref)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw TTMError.crypto("keychain read failed: \(status)")
        }
        return String(data: data, encoding: .utf8)
    }

    public func write(_ value: String, ref: String) throws {
        let data = Data(value.utf8)
        let query = baseQuery(ref)
        let attributes: [String: Any] = [kSecValueData as String: data]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            let addStatus = SecItemAdd(insert as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw TTMError.crypto("keychain add failed: \(addStatus)") }
        } else if status != errSecSuccess {
            throw TTMError.crypto("keychain update failed: \(status)")
        }
    }

    public func delete(ref: String) throws {
        let status = SecItemDelete(baseQuery(ref) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw TTMError.crypto("keychain delete failed: \(status)")
        }
    }

    private func baseQuery(_ ref: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: ref,
        ]
    }
}
