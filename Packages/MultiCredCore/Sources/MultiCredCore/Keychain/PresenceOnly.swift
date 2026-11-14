import Foundation

/// Keychain view that answers "does the item exist?" and nothing else. Writes
/// and deletes are refused; it has no way to read a value in the first place.
public struct PresenceOnlyKeychain: KeychainStore {
    private let inner: any KeychainStore

    public init(inner: any KeychainStore) { self.inner = inner }

    public func setSecret(_ value: Data, account: String) throws { throw ReadOnlyViolation("writing to the Keychain") }
    public func deleteItem(account: String) throws { throw ReadOnlyViolation("deleting from the Keychain") }
    public func containsItem(account: String) throws -> Bool { try inner.containsItem(account: account) }
    public func allAccounts() throws -> [String] { try inner.allAccounts() }
    public func isLegacyItem(account: String) throws -> Bool { try inner.isLegacyItem(account: account) }
}

/// Claude credentials view that only reports whether a vault entry exists.
/// Reading any credential, or changing one, is refused.
public struct PresenceOnlyClaudeCredentialStore: ClaudeCredentialStore {
    private let inner: any ClaudeCredentialStore

    public init(inner: any ClaudeCredentialStore) { self.inner = inner }

    public func hasVaultEntry(_ key: String) throws -> Bool { try inner.hasVaultEntry(key) }

    public func readFolderItem(configDir: String?) throws -> Data? { throw ReadOnlyViolation("reading Claude Code credentials") }
    public func writeFolderItem(configDir: String?, data: Data) throws { throw ReadOnlyViolation("writing Claude Code credentials") }
    public func readVault(_ key: String) throws -> Data? { throw ReadOnlyViolation("reading a stored login") }
    public func writeVault(_ key: String, data: Data) throws { throw ReadOnlyViolation("writing a stored login") }
    public func deleteVault(_ key: String) throws { throw ReadOnlyViolation("deleting a stored login") }
    public func deleteFolderItem(configDir: String?) throws { throw ReadOnlyViolation("deleting Claude Code credentials") }
}
