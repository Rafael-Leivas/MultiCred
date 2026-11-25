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

    /// A folder's credential item as an object. A damaged item (e.g. cut short
    /// by an earlier failed write) is not an error: the members that are still
    /// complete are kept (one level deep, so whole MCP logins inside `mcpOAuth`
    /// survive) and `intact` is false.
    static func folderItem(_ data: Data?) -> (object: [String: Any], intact: Bool) {
        guard let data else { return ([:], true) }
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { return (object, true) }
        return (salvage(Array(data)), false)
    }

    /// Complete members of the object that starts at the first `{`.
    static func salvage(_ bytes: [UInt8]) -> [String: Any] {
        guard let open = bytes.firstIndex(of: UInt8(ascii: "{")) else { return [:] }
        return salvageObject(bytes, from: open, depth: 0)
    }

    private static func salvageObject(_ b: [UInt8], from open: Int, depth: Int) -> [String: Any] {
        var result: [String: Any] = [:]
        var i = open + 1
        while true {
            i = skip(b, i, " \t\r\n,")
            guard i < b.count, b[i] == UInt8(ascii: "\"") else { return result }
            guard let keyEnd = endOfString(b, i) else { return result }
            guard let key = try? JSONSerialization.jsonObject(with: Data(b[i...keyEnd]), options: .fragmentsAllowed) as? String else { return result }
            i = skip(b, keyEnd + 1, " \t\r\n:")
            guard i < b.count else { return result }
            if let valueEnd = endOfValue(b, i),
               let value = try? JSONSerialization.jsonObject(with: Data(b[i...valueEnd]), options: .fragmentsAllowed) {
                result[key] = value
                i = valueEnd + 1
            } else {
                // Cut off inside this value: keep what is complete inside it.
                if depth == 0, b[i] == UInt8(ascii: "{") {
                    let inner = salvageObject(b, from: i, depth: 1)
                    if !inner.isEmpty { result[key] = inner }
                }
                return result
            }
        }
    }

    private static func skip(_ b: [UInt8], _ start: Int, _ chars: String) -> Int {
        let set = Set(chars.utf8)
        var i = start
        while i < b.count, set.contains(b[i]) { i += 1 }
        return i
    }

    private static func endOfString(_ b: [UInt8], _ quote: Int) -> Int? {
        var i = quote + 1
        while i < b.count {
            if b[i] == UInt8(ascii: "\\") { i += 2; continue }
            if b[i] == UInt8(ascii: "\"") { return i }
            i += 1
        }
        return nil
    }

    /// Index of the last byte of the value starting at `start`, or nil if cut off.
    private static func endOfValue(_ b: [UInt8], _ start: Int) -> Int? {
        switch b[start] {
        case UInt8(ascii: "\""):
            return endOfString(b, start)
        case UInt8(ascii: "{"), UInt8(ascii: "["):
            var depth = 0
            var i = start
            while i < b.count {
                switch b[i] {
                case UInt8(ascii: "\""):
                    guard let end = endOfString(b, i) else { return nil }
                    i = end
                case UInt8(ascii: "{"), UInt8(ascii: "["): depth += 1
                case UInt8(ascii: "}"), UInt8(ascii: "]"):
                    depth -= 1
                    if depth == 0 { return i }
                default: break
                }
                i += 1
            }
            return nil
        default:
            var i = start
            while i < b.count, ![UInt8(ascii: ","), UInt8(ascii: "}"), UInt8(ascii: "]")].contains(b[i]) { i += 1 }
            return i < b.count ? i - 1 : nil
        }
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
            undo.append(try restoreOwnLogin(into: other))
            occupancy.accountByFolder[ClaudeFolderOccupancy.key(other)] = nil
        }

        undo.append(try saveBack(from: configDir, owner: current))
        if let account {
            undo.append(try write(record: try vaultRecord(account.uuidString), into: configDir))
        } else {
            undo.append(try restoreOwnLogin(into: configDir))
        }
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
        // A damaged item cannot be trusted to hold the owner's login (a failed
        // write may have left another account's login in it): never save it.
        let (item, intact) = ClaudeLoginJSON.folderItem(try store.readFolderItem(configDir: configDir))
        guard intact, let oauth = item["claudeAiOauth"] as? [String: Any] else {
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

    /// Puts the folder's original login back. A folder that had no login of its
    /// own before MultiCred put an account in it goes back to having none.
    private func restoreOwnLogin(into configDir: String?) throws -> @Sendable () throws -> Void {
        if let saved = try store.readVault(Self.ownLoginKey(configDir)) {
            return try write(record: try ClaudeLoginRecord.decode(saved), into: configDir)
        }
        let previousItem = try store.readFolderItem(configDir: configDir)
        if previousItem != nil {
            var object = ClaudeLoginJSON.folderItem(previousItem).object
            object.removeValue(forKey: "claudeAiOauth")
            try writeFolderItemSafely(configDir: configDir, data: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), previous: previousItem)
        }
        let stateFile = ClaudeAccountFiles.stateFile(for: ClaudeFolder.ownLogin(configDir), environment: environment)
        let previousState = try? Data(contentsOf: stateFile)
        if let previousState, var state = try? ClaudeLoginJSON.object(previousState), state["oauthAccount"] != nil {
            state.removeValue(forKey: "oauthAccount")
            let data = try JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try AtomicFileWriter.write(data, to: stateFile, permissions: 0o600, followSymlink: true)
        }
        let store = self.store
        return {
            if let previousItem { try store.writeFolderItem(configDir: configDir, data: previousItem) }
            try FileRestore.restore(previousState, to: stateFile)
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
        // A damaged item keeps only its complete members (MCP logins).
        var object = ClaudeLoginJSON.folderItem(previousItem).object
        object["claudeAiOauth"] = try ClaudeLoginJSON.object(record.oauth)
        try writeFolderItemSafely(configDir: configDir, data: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), previous: previousItem)

        let stateFile = ClaudeAccountFiles.stateFile(for: ClaudeFolder.ownLogin(configDir), environment: environment)
        let previousState = try? Data(contentsOf: stateFile)
        if let account = record.account {
            do {
                var state = previousState.flatMap { try? ClaudeLoginJSON.object($0) } ?? [:]
                state["oauthAccount"] = try ClaudeLoginJSON.object(account)
                let data = try JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
                try AtomicFileWriter.write(data, to: stateFile, permissions: 0o600, followSymlink: true)
            } catch {
                if let previousItem { try? store.writeFolderItem(configDir: configDir, data: previousItem) }
                throw error
            }
        }
        return {
            if let previousItem { try store.writeFolderItem(configDir: configDir, data: previousItem) }
            if record.account != nil { try FileRestore.restore(previousState, to: stateFile) }
        }
    }

    /// Writes the folder item; if the write fails it puts the previous content
    /// back right away. The transaction's undo only exists after a step
    /// succeeds, so a failed write must clean up after itself (2026-11-25: a
    /// cut-off write left another account's login in ~/.claude).
    private func writeFolderItemSafely(configDir: String?, data: Data, previous: Data?) throws {
        do {
            try store.writeFolderItem(configDir: configDir, data: data)
        } catch {
            if let previous { try? store.writeFolderItem(configDir: configDir, data: previous) }
            throw error
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
