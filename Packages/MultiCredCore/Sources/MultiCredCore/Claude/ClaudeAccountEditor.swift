import Foundation

/// Where a profile keeps its Claude folder.
public enum ClaudeFolderChoice: Equatable, Sendable {
    /// `~/.claude`, used with `CLAUDE_CONFIG_DIR` unset.
    case defaultFolder
    /// A folder that already exists.
    case existing(String)
    /// A folder MultiCred creates now (0700).
    case new(String)
}

public enum ClaudeAccountError: Error, Equatable, Sendable {
    case invalidPath(String)
    case folderMissing(String)
    case notADirectory(String)
    /// In test mode every folder must live inside the sandbox home.
    case outsideSandbox(String)
    case createFailed(String)
    case invalidToken
    case keychain(String)
    case invalid([ValidationIssue])
}

/// Claude folders for profiles, and Claude token accounts.
public enum ClaudeAccountEditor {
    // MARK: Folders (belong to profiles)

    /// Canonical folder for the choice, creating it for `.new` (and for the
    /// default folder if it does not exist yet). nil = default `~/.claude`.
    public static func prepareFolder(_ choice: ClaudeFolderChoice, environment: SystemEnvironment) throws -> String? {
        let configDir: String?
        switch choice {
        case .defaultFolder:
            configDir = nil
        case let .existing(path), let .new(path):
            do {
                configDir = try ClaudePaths.canonicalConfigDir(path, environment: environment)
            } catch {
                throw ClaudeAccountError.invalidPath(path)
            }
        }
        let directory = configDir ?? ClaudePaths.defaultConfigDir(environment: environment)
        if environment.mode != .real, !directory.hasPrefix(environment.home.path + "/") {
            throw ClaudeAccountError.outsideSandbox(directory)
        }
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory)
        if exists, !isDirectory.boolValue { throw ClaudeAccountError.notADirectory(directory) }
        switch choice {
        case .existing where !exists:
            throw ClaudeAccountError.folderMissing(directory)
        case .new where !exists, .defaultFolder where !exists:
            do {
                try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            } catch {
                throw ClaudeAccountError.createFailed(error.localizedDescription)
            }
        default:
            break
        }
        return configDir
    }

    // MARK: Token accounts

    /// Looks like an OAuth token from `claude setup-token`: one line, no spaces.
    public static func isPlausibleToken(_ token: String) -> Bool {
        token.count >= 20 && token.count <= 2048
            && token.range(of: #"^[A-Za-z0-9._\-]+$"#, options: .regularExpression) != nil
    }

    /// Validates first, then stores the token; on a Keychain error nothing is added.
    public static func addTokenAccount(
        nickname: String,
        email: String?,
        color: ProfileColor,
        token: String,
        to config: Config,
        keychain: any KeychainStore
    ) throws -> (Config, ClaudeAccount) {
        let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isPlausibleToken(value) else { throw ClaudeAccountError.invalidToken }
        let cleanEmail = email?.trimmingCharacters(in: .whitespaces)
        let account = ClaudeAccount(
            nickname: nickname.trimmingCharacters(in: .whitespaces),
            email: (cleanEmail?.isEmpty ?? true) ? nil : cleanEmail,
            color: color,
            kind: .token
        )
        var updated = config
        updated.claudeAccounts.append(account)
        let issues = Validation.issues(in: updated)
        guard issues.isEmpty else { throw ClaudeAccountError.invalid(issues) }
        try store(value, for: account, keychain: keychain)
        return (updated, account)
    }

    /// Replaces the token of an existing account (new `claude setup-token`).
    public static func replaceToken(of account: ClaudeAccount, with token: String, keychain: any KeychainStore) throws {
        let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isPlausibleToken(value) else { throw ClaudeAccountError.invalidToken }
        try store(value, for: account, keychain: keychain)
    }

    private static func store(_ token: String, for account: ClaudeAccount, keychain: any KeychainStore) throws {
        do {
            try keychain.setSecret(Data(token.utf8), account: account.keychainAccount)
        } catch {
            throw ClaudeAccountError.keychain(String(describing: error))
        }
    }

    /// Removes the account and its token; profiles using it fall back to their
    /// folder's own login.
    public static func remove(_ accountId: UUID, from config: Config, keychain: any KeychainStore) -> Config {
        if let account = config.claudeAccount(accountId) {
            try? keychain.deleteItem(account: account.keychainAccount)
        }
        var updated = config
        updated.claudeAccounts.removeAll { $0.id == accountId }
        for index in updated.profiles.indices where updated.profiles[index].claudeAccountId == accountId {
            updated.profiles[index].claudeAccountId = nil
        }
        return updated
    }

    public static func profilesUsing(_ accountId: UUID, in config: Config) -> [Profile] {
        config.profiles.filter { $0.claudeAccountId == accountId }
    }
}

/// Reads the token printed by `claude setup-token`. The token is kept only to
/// hand it to the Keychain; the visible transcript has it masked.
public struct SetupTokenParser: Sendable {
    private var login = LoginOutputParser()
    public private(set) var token: String?

    public init() {}

    /// Login events (browser, code prompt, success), as for `claude auth login`.
    public mutating func consume(_ bytes: some Sequence<UInt8>) -> [LoginEvent] {
        let events = login.consume(bytes)
        if token == nil, let range = login.transcript.range(of: #"sk-ant-oat[0-9]{2}-[A-Za-z0-9_\-]{20,}"#, options: .regularExpression) {
            token = String(login.transcript[range])
        }
        return events
    }

    /// Transcript with the token masked.
    public var maskedTranscript: String {
        Redactor.redact(login.transcript, secrets: token.map { [$0] } ?? [])
    }
}

/// Test-mode stand-in for `claude setup-token`: prints a fake token.
public enum SetupTokenSimulator {
    public static let executable = "/bin/sh"
    public static let fakeToken = "sk-ant-oat01-SIMULADO-modo-de-teste-0000000000"
    public static var arguments: [String] { ["-c", script] }

    static let script = #"""
    printf '[MODO DE TESTE: simulação do claude setup-token]\r\n'
    printf 'Opening browser to sign in...\r\n'
    sleep 1
    printf 'Paste code here if prompted > '
    IFS= read -r code
    printf '\r\nLogin successful.\r\n'
    printf 'Your OAuth token (valid for 1 year):\r\n\r\nsk-ant-oat01-SIMULADO-modo-de-teste-0000000000\r\n'
    """#
}
