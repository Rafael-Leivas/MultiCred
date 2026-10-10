import CryptoKit
import Foundation

/// The eight profile colors from the design tokens (`perfis-design/tokens.json`).
public enum ProfileColor: String, Codable, CaseIterable, Sendable {
    case indigo, blue, teal, green, orange, red, pink, graphite

    public var hex: String {
        switch self {
        case .indigo: "#5856D6"
        case .blue: "#0064E0"
        case .teal: "#0E8A9E"
        case .green: "#1C8A36"
        case .orange: "#D9770B"
        case .red: "#C8101E"
        case .pink: "#B23A8F"
        case .graphite: "#6E6E73"
        }
    }
}

/// What the menu bar shows for a profile: a letter or an SF Symbol name.
public enum ProfileIcon: Codable, Hashable, Sendable {
    case letter(String)
    case symbol(String)
}

public enum ShellKind: String, Codable, CaseIterable, Sendable {
    case zsh, bash, fish
}

public struct GitIdentity: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var nickname: String
    public var name: String
    public var email: String
    /// Private key for `core.sshCommand`; nil leaves the user's SSH setup alone.
    public var sshKeyPath: String?
    public var color: ProfileColor

    public init(id: UUID = UUID(), nickname: String, name: String, email: String, sshKeyPath: String? = nil, color: ProfileColor) {
        self.id = id
        self.nickname = nickname
        self.name = name
        self.email = email
        self.sshKeyPath = sshKeyPath
        self.color = color
    }
}

public struct GitHubAccount: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var nickname: String
    public var username: String
    public var host: String
    public var color: ProfileColor
    /// Commits and PRs made by Claude Code in profiles using this account carry
    /// Claude as co-author (Claude Code's default). Applied to the profile's
    /// Claude folder settings.json on each profile switch.
    public var claudeCoAuthor: Bool

    public init(id: UUID = UUID(), nickname: String, username: String, host: String = "github.com", color: ProfileColor, claudeCoAuthor: Bool = true) {
        self.id = id
        self.nickname = nickname
        self.username = username
        self.host = host
        self.color = color
        self.claudeCoAuthor = claudeCoAuthor
    }

    private enum CodingKeys: String, CodingKey { case id, nickname, username, host, color, claudeCoAuthor }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        nickname = try container.decode(String.self, forKey: .nickname)
        username = try container.decode(String.self, forKey: .username)
        host = try container.decode(String.self, forKey: .host)
        color = try container.decode(ProfileColor.self, forKey: .color)
        claudeCoAuthor = try container.decodeIfPresent(Bool.self, forKey: .claudeCoAuthor) ?? true
    }
}

public enum ClaudeAccountKind: String, Codable, Sendable {
    /// Config v2: a credential only. Its long-lived OAuth token (`claude
    /// setup-token`) lives in the Keychain and is exported as
    /// `CLAUDE_CODE_OAUTH_TOKEN`; the Claude folder (agents, skills, chats)
    /// belongs to the profile and does not change.
    case token
    /// Config v1 only: an account was a whole `CLAUDE_CONFIG_DIR` folder.
    /// Migrated into the profiles' folders on load (`ConfigMigration`).
    case folder
}

/// A Claude account = who authenticates and pays. Not where the chats live.
public struct ClaudeAccount: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var nickname: String
    /// E-mail of the account, typed by the user; display only.
    public var email: String?
    public var color: ProfileColor
    public var kind: ClaudeAccountKind
    /// Only for `.folder` (config v1) and for status checks of a folder's own
    /// login: canonical absolute path, or nil for the default `~/.claude`.
    public var configDir: String?

    public init(id: UUID = UUID(), nickname: String, email: String? = nil, color: ProfileColor, kind: ClaudeAccountKind = .token, configDir: String? = nil) {
        self.id = id
        self.nickname = nickname
        self.email = email
        self.color = color
        self.kind = kind
        self.configDir = configDir
    }

    /// Keychain account name of the token.
    public var keychainAccount: String { id.uuidString }

    public var isDefault: Bool { configDir == nil }

    enum CodingKeys: String, CodingKey { case id, nickname, email, color, kind, configDir }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        nickname = try container.decode(String.self, forKey: .nickname)
        email = try container.decodeIfPresent(String.self, forKey: .email)
        color = try container.decode(ProfileColor.self, forKey: .color)
        // Config v1 had no kind: every account was a folder.
        kind = try container.decodeIfPresent(ClaudeAccountKind.self, forKey: .kind) ?? .folder
        configDir = try container.decodeIfPresent(String.self, forKey: .configDir)
    }
}

/// A Claude Code config folder (agents, skills, chats, settings) as used by a
/// profile. nil path = the default `~/.claude` (with `CLAUDE_CONFIG_DIR` unset).
public enum ClaudeFolder {
    public static let tokenVariable = "CLAUDE_CODE_OAUTH_TOKEN"

    /// Override meaning "the folder's own login", even when the profile's
    /// default is a token account.
    public static let ownLoginOverride = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1))

    /// The override to store for "use this account now" (nil = folder login):
    /// nil when it matches the profile's default, so the state stays clean.
    public static func override(for accountId: UUID?, profile: Profile?) -> UUID? {
        if accountId == profile?.claudeAccountId { return nil }
        return accountId ?? ownLoginOverride
    }

    /// A pseudo account to reuse status helpers for a folder's own login. Its id
    /// is derived from the path, so status caches keep working across calls.
    public static func ownLogin(_ configDir: String?) -> ClaudeAccount {
        let digest = Array(SHA256.hash(data: Data("multicred-folder:\(configDir ?? "~/.claude")".utf8)))
        let id = UUID(uuid: (digest[0], digest[1], digest[2], digest[3], digest[4], digest[5], digest[6], digest[7],
                             digest[8], digest[9], digest[10], digest[11], digest[12], digest[13], digest[14], digest[15]))
        return ClaudeAccount(id: id, nickname: "", color: .graphite, kind: .folder, configDir: configDir)
    }
}

public enum APIProvider: String, Codable, CaseIterable, Sendable {
    case openai, gemini, anthropic, mistral, groq, other

    public var displayName: String {
        switch self {
        case .openai: "OpenAI"
        case .gemini: "Gemini"
        case .anthropic: "Anthropic API"
        case .mistral: "Mistral"
        case .groq: "Groq"
        case .other: "Outra"
        }
    }

    public var defaultEnvVar: String {
        switch self {
        case .openai: "OPENAI_API_KEY"
        case .gemini: "GEMINI_API_KEY"
        case .anthropic: "ANTHROPIC_API_KEY"
        case .mistral: "MISTRAL_API_KEY"
        case .groq: "GROQ_API_KEY"
        case .other: ""
        }
    }
}

/// An API key exported as an environment variable. The value lives only in the
/// Keychain, under `KeychainConstants.apiKeyService` with account = `id`.
public struct APIKeyAccount: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var nickname: String
    public var provider: APIProvider
    public var envVar: String
    public var color: ProfileColor

    public init(id: UUID = UUID(), nickname: String, provider: APIProvider, envVar: String? = nil, color: ProfileColor) {
        self.id = id
        self.nickname = nickname
        self.provider = provider
        self.envVar = envVar ?? provider.defaultEnvVar
        self.color = color
    }

    public var keychainAccount: String { id.uuidString }
}

/// A combination of accounts. A nil git/GitHub reference means "do not switch
/// that item". Claude is split in two: the profile always owns a Claude folder
/// (agents, skills, chats; nil = default `~/.claude`), and optionally a Claude
/// account whose token is used instead of the folder's own login.
public struct Profile: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var color: ProfileColor
    public var icon: ProfileIcon
    public var gitIdentityId: UUID?
    public var githubAccountId: UUID?
    /// Claude folder of this profile: canonical absolute path, nil = `~/.claude`.
    public var claudeConfigDir: String?
    /// Token account to authenticate with; nil = the folder's own login.
    public var claudeAccountId: UUID?
    public var apiKeyIds: [UUID]

    public init(
        id: UUID = UUID(),
        name: String,
        color: ProfileColor,
        icon: ProfileIcon? = nil,
        gitIdentityId: UUID? = nil,
        githubAccountId: UUID? = nil,
        claudeConfigDir: String? = nil,
        claudeAccountId: UUID? = nil,
        apiKeyIds: [UUID] = []
    ) {
        self.id = id
        self.name = name
        self.color = color
        self.icon = icon ?? .letter(String(name.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased())
        self.gitIdentityId = gitIdentityId
        self.githubAccountId = githubAccountId
        self.claudeConfigDir = claudeConfigDir
        self.claudeAccountId = claudeAccountId
        self.apiKeyIds = apiKeyIds
    }
}

public enum SwitchFeedback: String, Codable, CaseIterable, Sendable {
    case hud, notification, none
}

public struct Settings: Codable, Hashable, Sendable {
    public var switchFeedback: SwitchFeedback
    public var enabledShells: [ShellKind]
    public var openAtLogin: Bool

    public init(switchFeedback: SwitchFeedback = .hud, enabledShells: [ShellKind] = [.zsh], openAtLogin: Bool = true) {
        self.switchFeedback = switchFeedback
        self.enabledShells = enabledShells
        self.openAtLogin = openAtLogin
    }
}

/// Everything in `config.json`. No secrets.
public struct Config: VersionedDocument, Hashable {
    /// 2: Claude accounts are tokens; the Claude folder belongs to the profile.
    public static let currentVersion = 2

    public var version: Int
    public var gitIdentities: [GitIdentity]
    public var githubAccounts: [GitHubAccount]
    public var claudeAccounts: [ClaudeAccount]
    public var apiKeys: [APIKeyAccount]
    /// Order is the menu order; the first nine get ⌘1…⌘9.
    public var profiles: [Profile]
    public var settings: Settings

    public init(
        gitIdentities: [GitIdentity] = [],
        githubAccounts: [GitHubAccount] = [],
        claudeAccounts: [ClaudeAccount] = [],
        apiKeys: [APIKeyAccount] = [],
        profiles: [Profile] = [],
        settings: Settings = Settings()
    ) {
        self.version = Self.currentVersion
        self.gitIdentities = gitIdentities
        self.githubAccounts = githubAccounts
        self.claudeAccounts = claudeAccounts
        self.apiKeys = apiKeys
        self.profiles = profiles
        self.settings = settings
    }

    public func profile(_ id: UUID?) -> Profile? { id.flatMap { id in profiles.first { $0.id == id } } }
    public func gitIdentity(_ id: UUID?) -> GitIdentity? { id.flatMap { id in gitIdentities.first { $0.id == id } } }
    public func githubAccount(_ id: UUID?) -> GitHubAccount? { id.flatMap { id in githubAccounts.first { $0.id == id } } }
    public func claudeAccount(_ id: UUID?) -> ClaudeAccount? { id.flatMap { id in claudeAccounts.first { $0.id == id } } }
    public func apiKey(_ id: UUID) -> APIKeyAccount? { apiKeys.first { $0.id == id } }

    /// Every variable MultiCred manages; all are unset before a profile's keys
    /// are exported (the Claude token variable included).
    public var managedEnvVars: [String] {
        Array(Set(apiKeys.map(\.envVar) + [ClaudeFolder.tokenVariable])).sorted()
    }
}

/// Moves a config v1 (Claude account = folder) to v2 (folder on the profile,
/// account = token). Each profile keeps the folder it used and authenticates
/// with that folder's own login, so nothing changes for the user until a
/// token account is added. Folder accounts disappear: they are now just folders.
public enum ConfigMigration {
    public static func migrate(_ config: Config) -> (Config, changed: Bool) {
        guard config.version < Config.currentVersion || config.claudeAccounts.contains(where: { $0.kind == .folder }) else {
            return (config, false)
        }
        var updated = config
        for index in updated.profiles.indices {
            guard let id = updated.profiles[index].claudeAccountId,
                  let account = config.claudeAccount(id), account.kind == .folder
            else { continue }
            updated.profiles[index].claudeConfigDir = account.configDir
            updated.profiles[index].claudeAccountId = nil
        }
        updated.claudeAccounts.removeAll { $0.kind == .folder }
        updated.version = Config.currentVersion
        return (updated, true)
    }
}

/// What is active right now (`state.json`). `generation` mirrors the
/// `generation` file the shell hooks watch.
public struct ActiveState: VersionedDocument, Hashable {
    public static let currentVersion = 1

    public var version: Int
    public var profileId: UUID?
    /// Set by "switch only the Claude account"; cleared by the next profile switch.
    public var claudeOverrideId: UUID?
    /// The Claude account actually applied last (profile or override).
    public var appliedClaudeAccountId: UUID?
    public var activatedAt: Date?
    public var generation: Int

    public init(
        profileId: UUID? = nil,
        claudeOverrideId: UUID? = nil,
        appliedClaudeAccountId: UUID? = nil,
        activatedAt: Date? = nil,
        generation: Int = 0
    ) {
        self.version = Self.currentVersion
        self.profileId = profileId
        self.claudeOverrideId = claudeOverrideId
        self.appliedClaudeAccountId = appliedClaudeAccountId
        self.activatedAt = activatedAt
        self.generation = generation
    }
}
