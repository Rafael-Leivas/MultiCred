import Foundation

/// Problems that make a configuration unsafe or impossible to apply.
/// The UI maps each case to a message; the core stays language-neutral.
public enum ValidationIssue: Hashable, Sendable {
    case emptyField(owner: UUID, field: String)
    case controlCharacters(owner: UUID, field: String)
    case invalidEmail(owner: UUID)
    case invalidGitHubUsername(owner: UUID)
    case invalidHost(owner: UUID)
    case invalidEnvVar(owner: UUID, name: String)
    case reservedEnvVar(owner: UUID, name: String)
    case duplicateEnvVarInProfile(profile: UUID, name: String)
    case invalidClaudeDirectory(owner: UUID)
    case duplicateClaudeDirectory(owner: UUID)
    case invalidSSHKeyPath(owner: UUID)
    case missingReference(profile: UUID, field: String)
    case duplicateID(UUID)
}

public enum Validation {
    static let reservedEnvVars: Set<String> = [
        "PATH", "HOME", "SHELL", "USER", "LOGNAME", "TMPDIR", "LANG", "TERM",
        "CLAUDE_CONFIG_DIR", "CLAUDE_CODE_OAUTH_TOKEN", "GH_CONFIG_DIR", "GH_TOKEN", "GITHUB_TOKEN",
    ]

    static func isCanonicalDirectory(_ dir: String) -> Bool {
        dir.hasPrefix("/") && ClaudePaths.standardize(dir) == dir && !hasControlCharacters(dir)
    }

    static func hasControlCharacters(_ value: String) -> Bool {
        value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    static func isValidEnvVarName(_ name: String) -> Bool {
        name.range(of: "^[A-Z_][A-Z0-9_]*$", options: .regularExpression) != nil
    }

    static func isValidGitHubUsername(_ name: String) -> Bool {
        name.range(of: "^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})$", options: .regularExpression) != nil
    }

    static func isValidHost(_ host: String) -> Bool {
        // Must start with a letter or digit: a leading "-" would be read as an option by gh.
        host.range(of: "^[A-Za-z0-9][A-Za-z0-9.-]*(:[0-9]+)?$", options: .regularExpression) != nil
    }

    static func isPlausibleEmail(_ email: String) -> Bool {
        email.range(of: "^[^@\\s]+@[^@\\s]+$", options: .regularExpression) != nil
    }

    /// Every issue in the configuration; empty means it can be applied.
    public static func issues(in config: Config) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []

        func text(_ value: String, owner: UUID, field: String, required: Bool = true) {
            if required, value.trimmingCharacters(in: .whitespaces).isEmpty {
                issues.append(.emptyField(owner: owner, field: field))
            }
            if hasControlCharacters(value) {
                issues.append(.controlCharacters(owner: owner, field: field))
            }
        }

        var ids = Set<UUID>()
        let allIDs = config.gitIdentities.map(\.id) + config.githubAccounts.map(\.id)
            + config.claudeAccounts.map(\.id) + config.apiKeys.map(\.id) + config.profiles.map(\.id)
        for id in allIDs where !ids.insert(id).inserted {
            issues.append(.duplicateID(id))
        }

        for identity in config.gitIdentities {
            text(identity.nickname, owner: identity.id, field: "nickname")
            text(identity.name, owner: identity.id, field: "name")
            text(identity.email, owner: identity.id, field: "email")
            if !isPlausibleEmail(identity.email) { issues.append(.invalidEmail(owner: identity.id)) }
            if let key = identity.sshKeyPath {
                if key.isEmpty || hasControlCharacters(key) || !(key.hasPrefix("/") || key.hasPrefix("~/")) {
                    issues.append(.invalidSSHKeyPath(owner: identity.id))
                }
            }
        }

        for account in config.githubAccounts {
            text(account.nickname, owner: account.id, field: "nickname")
            if !isValidGitHubUsername(account.username) { issues.append(.invalidGitHubUsername(owner: account.id)) }
            if !isValidHost(account.host) { issues.append(.invalidHost(owner: account.id)) }
        }

        var folderAccountDirectories = Set<String?>()
        for account in config.claudeAccounts {
            text(account.nickname, owner: account.id, field: "nickname")
            if let email = account.email, !email.isEmpty, !isPlausibleEmail(email) {
                issues.append(.invalidEmail(owner: account.id))
            }
            // Folder accounts only exist before migration (config v1).
            guard account.kind == .folder else { continue }
            if let dir = account.configDir, !isCanonicalDirectory(dir) {
                issues.append(.invalidClaudeDirectory(owner: account.id))
            }
            if !folderAccountDirectories.insert(account.configDir).inserted {
                issues.append(.duplicateClaudeDirectory(owner: account.id))
            }
        }

        for key in config.apiKeys {
            text(key.nickname, owner: key.id, field: "nickname")
            if !isValidEnvVarName(key.envVar) {
                issues.append(.invalidEnvVar(owner: key.id, name: key.envVar))
            } else if reservedEnvVars.contains(key.envVar) {
                issues.append(.reservedEnvVar(owner: key.id, name: key.envVar))
            }
        }

        for profile in config.profiles {
            text(profile.name, owner: profile.id, field: "name")
            if let id = profile.gitIdentityId, config.gitIdentity(id) == nil {
                issues.append(.missingReference(profile: profile.id, field: "git"))
            }
            if let id = profile.githubAccountId, config.githubAccount(id) == nil {
                issues.append(.missingReference(profile: profile.id, field: "github"))
            }
            if let id = profile.claudeAccountId, config.claudeAccount(id) == nil {
                issues.append(.missingReference(profile: profile.id, field: "claude"))
            }
            if let dir = profile.claudeConfigDir, !isCanonicalDirectory(dir) {
                issues.append(.invalidClaudeDirectory(owner: profile.id))
            }
            var seenVars = Set<String>()
            for keyID in profile.apiKeyIds {
                guard let key = config.apiKey(keyID) else {
                    issues.append(.missingReference(profile: profile.id, field: "apiKey"))
                    continue
                }
                if !seenVars.insert(key.envVar).inserted {
                    issues.append(.duplicateEnvVarInProfile(profile: profile.id, name: key.envVar))
                }
            }
        }
        return issues
    }
}
