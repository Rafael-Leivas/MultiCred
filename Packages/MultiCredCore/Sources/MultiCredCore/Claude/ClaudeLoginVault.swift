import Foundation

// Live Claude account switching (D39). A "login" Claude account is a full
// claude.ai login (from `claude auth login` in a throwaway folder): access and
// refresh tokens, kept in MultiCred's own Keychain vault. Switching puts it into
// the `claudeAiOauth` key of the profile folder's own `Claude Code-credentials…`
// item, the same place `/login` writes, so sessions already open adopt it
// without restarting. Everything else in that item (MCP logins) is kept.
//
// Refresh tokens rotate, so the copy that lives in a folder is always newer than
// the vault's. Before a folder changes account, its current login is saved back
// to whoever owns it: a MultiCred account, or the folder's own original login.
// An account lives in at most one folder at a time.

/// Raw access to the Keychain items involved. The real implementation runs
/// `/usr/bin/security`; tests use `InMemoryClaudeCredentialStore`.
public protocol ClaudeCredentialStore: Sendable {
    /// The whole `Claude Code-credentials…` item of a folder (nil = no item).
    func readFolderItem(configDir: String?) throws -> Data?
    func writeFolderItem(configDir: String?, data: Data) throws
    /// MultiCred's vault entry for a key (account id or a folder's own login).
    func readVault(_ key: String) throws -> Data?
    func writeVault(_ key: String, data: Data) throws
    func deleteVault(_ key: String) throws
    /// Item of a throwaway folder used to log in a new account.
    func deleteFolderItem(configDir: String?) throws
}

public enum ClaudeLoginError: Error, Equatable {
    case noLoginInFolder
    case vaultEntryMissing(String)
    case unreadable(String)
    case securityFailed(String)
}

/// What MultiCred keeps for one login: the `claudeAiOauth` object (secret) and
/// the `oauthAccount` object Claude Code shows as "logged in as" (not secret).
public struct ClaudeLoginRecord: Sendable, Equatable {
    public var oauth: Data
    public var account: Data?

    public init(oauth: Data, account: Data?) {
        self.oauth = oauth
        self.account = account
    }

    public var email: String? {
        account.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["emailAddress"] as? String
    }

    func encoded() throws -> Data {
        var object: [String: Any] = ["claudeAiOauth": try ClaudeLoginJSON.object(oauth)]
        if let account { object["oauthAccount"] = try ClaudeLoginJSON.object(account) }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    static func decode(_ data: Data) throws -> ClaudeLoginRecord {
        let object = try ClaudeLoginJSON.object(data)
        guard let oauth = object["claudeAiOauth"] as? [String: Any] else { throw ClaudeLoginError.unreadable("vault entry") }
        let account = object["oauthAccount"] as? [String: Any]
        return ClaudeLoginRecord(
            oauth: try JSONSerialization.data(withJSONObject: oauth, options: [.sortedKeys]),
            account: try account.map { try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) }
        )
    }
}

enum ClaudeLoginJSON {
    static func object(_ data: Data) throws -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeLoginError.unreadable("json")
        }
        return object
    }
}

/// Which login each folder currently holds. Absent = the folder's own login.
public struct ClaudeFolderOccupancy: Codable, Equatable, Sendable {
    public var accountByFolder: [String: UUID] = [:]
    public init() {}

    public static func key(_ configDir: String?) -> String { configDir ?? "~/.claude" }

    public func account(in configDir: String?) -> UUID? { accountByFolder[Self.key(configDir)] }
    /// The folder holding `account` (`.some(nil)` = ~/.claude), or nil when none does.
    public func folder(holding account: UUID) -> String?? {
        guard let key = accountByFolder.first(where: { $0.value == account })?.key else { return nil }
        let folder: String? = key == "~/.claude" ? nil : key
        return .some(folder)
    }
}

public struct ClaudeLoginSwitcher: Sendable {
    let environment: SystemEnvironment
    let store: any ClaudeCredentialStore
    let occupancyFile: URL

    public init(environment: SystemEnvironment, store: any ClaudeCredentialStore) {
        self.environment = environment
        self.store = store
        occupancyFile = AppPaths(environment: environment).root.appendingPathComponent("claude-folders.json")
    }

    /// Vault key of a folder's own (original) login.
    public static func ownLoginKey(_ configDir: String?) -> String {
        ClaudeFolder.ownLogin(configDir).id.uuidString
    }

    public func occupancy() -> ClaudeFolderOccupancy {
        (try? Data(contentsOf: occupancyFile)).flatMap { try? JSONDecoder().decode(ClaudeFolderOccupancy.self, from: $0) } ?? ClaudeFolderOccupancy()
    }

    func saveOccupancy(_ value: ClaudeFolderOccupancy) throws {
        try AtomicFileWriter.write(try JSONEncoder().encode(value), to: occupancyFile, permissions: 0o600)
    }

    // MARK: Capture (new account)

    /// Reads the login a throwaway folder just got from `claude auth login`.
    public func capture(fromScratch configDir: String) throws -> ClaudeLoginRecord {
        guard let item = try store.readFolderItem(configDir: configDir),
              let oauth = try ClaudeLoginJSON.object(item)["claudeAiOauth"] as? [String: Any],
              oauth["accessToken"] != nil else {
            throw ClaudeLoginError.noLoginInFolder
        }
        return ClaudeLoginRecord(
            oauth: try JSONSerialization.data(withJSONObject: oauth, options: [.sortedKeys]),
            account: readDisplayedAccount(configDir: configDir)
        )
    }

    public func storeNewAccount(_ id: UUID, record: ClaudeLoginRecord) throws {
        try store.writeVault(id.uuidString, data: try record.encoded())
    }

    /// A new login for an existing account (signed in again). If it is live in
    /// a folder, that folder gets it right away.
    public func replaceLogin(_ id: UUID, record: ClaudeLoginRecord) throws {
        try storeNewAccount(id, record: record)
        if case let .some(folder) = occupancy().folder(holding: id) {
            _ = try write(record: record, into: folder)
        }
    }

    public func removeAccount(_ id: UUID) throws {
        // If it is live in a folder, that folder goes back to its own login first.
        if case let .some(folder) = occupancy().folder(holding: id) {
            try place(nil, in: folder)
        }
        try store.deleteVault(id.uuidString)
    }

    // MARK: Switch

    /// Puts `account` (nil = the folder's own login) into the folder's
    /// credential item. Returns an undo for the transaction.
    @discardableResult
    public func place(_ account: UUID?, in configDir: String?) throws -> @Sendable () throws -> Void {
        var occupancy = occupancy()
        let current = occupancy.account(in: configDir)
        guard current != account else { return {} }

        var undo: [@Sendable () throws -> Void] = []
        let originalOccupancy = occupancy

        // The account may be live in another folder: take it back from there.
        if let account, case let .some(other) = occupancy.folder(holding: account), other != configDir {
            undo.append(try saveBack(from: other, owner: account))
            undo.append(try write(record: try vaultRecord(Self.ownLoginKey(other)), into: other))
            occupancy.accountByFolder[ClaudeFolderOccupancy.key(other)] = nil
        }

        undo.append(try saveBack(from: configDir, owner: current))
        let targetKey = account?.uuidString ?? Self.ownLoginKey(configDir)
        undo.append(try write(record: try vaultRecord(targetKey), into: configDir))
        occupancy.accountByFolder[ClaudeFolderOccupancy.key(configDir)] = account
        try saveOccupancy(occupancy)

        let steps = undo
        return {
            for step in steps.reversed() { try step() }
            try saveOccupancy(originalOccupancy)
        }
    }

    /// Saves the folder's live login to its owner's vault entry (rotated tokens).
    private func saveBack(from configDir: String?, owner: UUID?) throws -> @Sendable () throws -> Void {
        guard let item = try store.readFolderItem(configDir: configDir),
              let oauth = try ClaudeLoginJSON.object(item)["claudeAiOauth"] as? [String: Any] else {
            return {}
        }
        let key = owner?.uuidString ?? Self.ownLoginKey(configDir)
        let previous = try store.readVault(key)
        let record = ClaudeLoginRecord(
            oauth: try JSONSerialization.data(withJSONObject: oauth, options: [.sortedKeys]),
            account: readDisplayedAccount(configDir: configDir)
        )
        try store.writeVault(key, data: try record.encoded())
        return {
            if let previous { try store.writeVault(key, data: previous) } else { try store.deleteVault(key) }
        }
    }

    private func vaultRecord(_ key: String) throws -> ClaudeLoginRecord {
        guard let data = try store.readVault(key) else { throw ClaudeLoginError.vaultEntryMissing(key) }
        return try ClaudeLoginRecord.decode(data)
    }

    /// Replaces only `claudeAiOauth` in the folder item and the displayed
    /// `oauthAccount` in its .claude.json.
    private func write(record: ClaudeLoginRecord, into configDir: String?) throws -> @Sendable () throws -> Void {
        let previousItem = try store.readFolderItem(configDir: configDir)
        var object = try previousItem.map(ClaudeLoginJSON.object) ?? [:]
        object["claudeAiOauth"] = try ClaudeLoginJSON.object(record.oauth)
        try store.writeFolderItem(configDir: configDir, data: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))

        let stateFile = ClaudeAccountFiles.stateFile(for: ClaudeFolder.ownLogin(configDir), environment: environment)
        let previousState = try? Data(contentsOf: stateFile)
        if let account = record.account {
            var state = previousState.flatMap { try? ClaudeLoginJSON.object($0) } ?? [:]
            state["oauthAccount"] = try ClaudeLoginJSON.object(account)
            let data = try JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try AtomicFileWriter.write(data, to: stateFile, permissions: 0o600, followSymlink: true)
        }
        return {
            if let previousItem { try store.writeFolderItem(configDir: configDir, data: previousItem) }
            if record.account != nil { try FileRestore.restore(previousState, to: stateFile) }
        }
    }

    private func readDisplayedAccount(configDir: String?) -> Data? {
        let stateFile = ClaudeAccountFiles.stateFile(for: ClaudeFolder.ownLogin(configDir), environment: environment)
        guard let data = try? Data(contentsOf: stateFile),
              let account = (try? ClaudeLoginJSON.object(data))?["oauthAccount"] as? [String: Any] else { return nil }
        return try? JSONSerialization.data(withJSONObject: account, options: [.sortedKeys])
    }
}

/// In-memory store for tests and the app's test mode.
public final class InMemoryClaudeCredentialStore: ClaudeCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    public private(set) var folders: [String: Data] = [:]
    public private(set) var vault: [String: Data] = [:]

    public init() {}

    private func key(_ configDir: String?) -> String { configDir ?? "~/.claude" }

    public func readFolderItem(configDir: String?) throws -> Data? { lock.withLock { folders[key(configDir)] } }
    public func writeFolderItem(configDir: String?, data: Data) throws { lock.withLock { folders[key(configDir)] = data } }
    public func deleteFolderItem(configDir: String?) throws { _ = lock.withLock { folders.removeValue(forKey: key(configDir)) } }
    public func readVault(_ key: String) throws -> Data? { lock.withLock { vault[key] } }
    public func writeVault(_ key: String, data: Data) throws { lock.withLock { vault[key] = data } }
    public func deleteVault(_ key: String) throws { _ = lock.withLock { vault.removeValue(forKey: key) } }
}
