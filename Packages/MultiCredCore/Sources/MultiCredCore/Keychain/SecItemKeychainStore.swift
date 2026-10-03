import Foundation
import Security

/// Real Keychain store in the user's login (file-based) keychain.
///
/// Items are created with an access list that trusts this app and
/// `/usr/bin/security`, so the shell hook can export the value without a prompt.
/// That uses the legacy `SecAccess` API, which only exists for file-based
/// keychains; the data-protection keychain cannot be read by `security`.
/// Trade-off documented in docs/PLAN.md §5.10.
public struct SecItemKeychainStore: KeychainStore {
    private let service: String
    private let trustedToolPath: String

    public init(service: String = KeychainConstants.apiKeyService, trustedToolPath: String = "/usr/bin/security") {
        self.service = service
        self.trustedToolPath = trustedToolPath
    }

    public func setSecret(_ value: Data, account: String) throws {
        try KeychainConstants.validate(account: account)
        guard !value.isEmpty else { throw KeychainError.emptySecret }

        // Replace instead of update so the access list is always the current one.
        try deleteItem(account: account)

        var attributes = baseQuery(account: account)
        attributes[kSecValueData as String] = value
        attributes[kSecAttrLabel as String] = "MultiCred API key"
        if let access = try makeAccess() {
            attributes[kSecAttrAccess as String] = access
        }
        try check(SecItemAdd(attributes as CFDictionary, nil))
    }

    public func containsItem(account: String) throws -> Bool {
        var query = baseQuery(account: account)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecItemNotFound { return false }
        try check(status)
        return true
    }

    public func deleteItem(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        if status == errSecItemNotFound { return }
        try check(status)
    }

    public func allAccounts() throws -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        try check(status)
        let items = result as? [[String: Any]] ?? []
        return items.compactMap { $0[kSecAttrAccount as String] as? String }.sorted()
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private func makeAccess() throws -> SecAccess? {
        var selfApp: SecTrustedApplication?
        var tool: SecTrustedApplication?
        try check(SecTrustedApplicationCreateFromPath(nil, &selfApp))
        try check(SecTrustedApplicationCreateFromPath(trustedToolPath, &tool))
        let trusted = [selfApp, tool].compactMap { $0 } as CFArray
        var access: SecAccess?
        try check(SecAccessCreate("MultiCred API key" as CFString, trusted, &access))
        return access
    }

    private func check(_ status: OSStatus) throws {
        switch status {
        case errSecSuccess: return
        case errSecUserCanceled: throw KeychainError.userCanceled
        case errSecAuthFailed, errSecInteractionNotAllowed: throw KeychainError.accessDenied
        default: throw KeychainError.unexpectedStatus(status)
        }
    }
}
