import Foundation
import Security

public protocol CredentialStoring: Sendable {
    func load() -> T3Credential?
    func save(_ credential: T3Credential) throws
    func clear()
}

/// Keeps the T3 credential in the Keychain, readable while the phone is locked
/// (Siri and CarPlay run on a locked phone) but only after the first unlock.
public struct KeychainCredentialStore: CredentialStoring {
    let service: String
    let account: String
    let accessGroup: String?

    public init(service: String = "com.shlokbhakta.teathree", account: String = "t3-credential", accessGroup: String? = nil) {
        self.service = service
        self.account = account
        self.accessGroup = accessGroup
    }

    private var baseQuery: [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }

    public func load() -> T3Credential? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else {
            return nil
        }
        return try? JSONDecoder().decode(T3Credential.self, from: data)
    }

    public func save(_ credential: T3Credential) throws {
        let data = try JSONEncoder().encode(credential)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        var status = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(baseQuery.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw T3Error.pairing("Couldn't save the credential to the Keychain (\(status)).")
        }
    }

    public func clear() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}

/// Plain JSON file, for the CLI and CI. Written with 0600 permissions.
public struct FileCredentialStore: CredentialStoring {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func load() -> T3Credential? {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(T3Credential.self, from: $0) }
    }

    public func save(_ credential: T3Credential) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(credential).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}

public enum TeaThree {
    public static let version = "0.1.0"
}
