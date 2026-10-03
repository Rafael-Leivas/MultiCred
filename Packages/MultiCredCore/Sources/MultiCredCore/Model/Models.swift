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

    public init(id: UUID = UUID(), nickname: String, username: String, host: String = "github.com", color: ProfileColor) {
        self.id = id
        self.nickname = nickname
        self.username = username
        self.host = host
        self.color = color
    }
}

public struct ClaudeAccount: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var nickname: String
    /// Last e-mail reported by Claude Code; display only.
    public var email: String?
    public var color: ProfileColor
    /// Canonical absolute path (see `ClaudePaths`), or nil for the default
    /// account (`~/.claude`, used when `CLAUDE_CONFIG_DIR` is not set).
    public var configDir: String?

    public init(id: UUID = UUID(), nickname: String, email: String? = nil, color: ProfileColor, configDir: String?) {
        self.id = id
        self.nickname = nickname
        self.email = email
        self.color = color
        self.configDir = configDir
    }

    public var isDefault: Bool { configDir == nil }
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

/// A combination of accounts. A nil reference means "do not switch that item".
public struct Profile: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var color: ProfileColor
    public var icon: ProfileIcon
    public var gitIdentityId: UUID?
    public var githubAccountId: UUID?
    public var claudeAccountId: UUID?
    public var apiKeyIds: [UUID]

    public init(
        id: UUID = UUID(),
        name: String,
        color: ProfileColor,
        icon: ProfileIcon? = nil,
        gitIdentityId: UUID? = nil,
        githubAccountId: UUID? = nil,
        claudeAccountId: UUID? = nil,
        apiKeyIds: [UUID] = []
    ) {
        self.id = id
        self.name = name
        self.color = color
        self.icon = icon ?? .letter(String(name.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased())
        self.gitIdentityId = gitIdentityId
        self.githubAccountId = githubAccountId
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
    public static let currentVersion = 1

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

    /// Every variable MultiCred manages; all are unset before a profile's keys are exported.
    public var managedEnvVars: [String] {
        Array(Set(apiKeys.map(\.envVar))).sorted()
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
