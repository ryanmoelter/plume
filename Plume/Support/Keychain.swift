import Foundation
import Security
import Synchronization

nonisolated protocol SecretStore: Sendable {
    func read(account: String) -> String?
    func write(_ secret: String, account: String) throws
    func delete(account: String) throws
}

nonisolated struct KeychainError: LocalizedError, Equatable {
    let status: OSStatus

    var errorDescription: String? {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)"
        return "Keychain error: \(message)"
    }
}

nonisolated struct KeychainSecretStore: SecretStore {
    /// Debug builds keep their own keys, so a Debug run never prompts for
    /// the installed app's key or deletes it.
#if DEBUG
    static let linearService = "com.ryanmoelter.Plume.linear.debug"
#else
    static let linearService = "com.ryanmoelter.Plume.linear"
#endif

    let service: String

    init(service: String = KeychainSecretStore.linearService) {
        self.service = service
    }

    private func identity(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    func read(account: String) -> String? {
        var query = identity(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func write(_ secret: String, account: String) throws {
        let data = Data(secret.utf8)
        let query = identity(account: account)
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        switch update {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var attributes = query
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let status = SecItemAdd(attributes as CFDictionary, nil)
            guard status == errSecSuccess else { throw KeychainError(status: status) }
        default:
            throw KeychainError(status: update)
        }
    }

    func delete(account: String) throws {
        let status = SecItemDelete(identity(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }
}

nonisolated final class InMemorySecretStore: SecretStore {
    private let secrets = Mutex<[String: String]>([:])

    init() {}

    func read(account: String) -> String? {
        secrets.withLock { $0[account] }
    }

    func write(_ secret: String, account: String) throws {
        secrets.withLock { $0[account] = secret }
    }

    func delete(account: String) throws {
        secrets.withLock { _ = $0.removeValue(forKey: account) }
    }
}
