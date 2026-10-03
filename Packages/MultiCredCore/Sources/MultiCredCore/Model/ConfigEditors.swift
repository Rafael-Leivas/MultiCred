import Foundation

public enum EditorError: Error, Equatable, Sendable {
    case invalid([ValidationIssue])
    case emptySecret
    case keychain(String)
}

/// Pure edits of `Config` for the Accounts and Profile screens. Every result is
/// validated; the caller saves it.
public enum ConfigEditor {
    // MARK: Git identities

    public static func upsert(_ identity: GitIdentity, in config: Config) throws -> Config {
        var updated = config
        var identity = identity
        identity.sshKeyPath = identity.sshKeyPath.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        replaceOrAppend(&updated.gitIdentities, identity)
        return try validated(updated)
    }

    public static func removeGitIdentity(_ id: UUID, from config: Config) -> Config {
        var updated = config
        updated.gitIdentities.removeAll { $0.id == id }
        for index in updated.profiles.indices where updated.profiles[index].gitIdentityId == id {
            updated.profiles[index].gitIdentityId = nil
        }
        return updated
    }

    // MARK: GitHub accounts

    public static func upsert(_ account: GitHubAccount, in config: Config) throws -> Config {
        var updated = config
        replaceOrAppend(&updated.githubAccounts, account)
        return try validated(updated)
    }

    public static func removeGitHubAccount(_ id: UUID, from config: Config) -> Config {
        var updated = config
        updated.githubAccounts.removeAll { $0.id == id }
        for index in updated.profiles.indices where updated.profiles[index].githubAccountId == id {
            updated.profiles[index].githubAccountId = nil
        }
        return updated
    }

    /// Adds gh logins MultiCred does not know yet (after `gh auth login`).
    public static func addMissingGitHubAccounts(_ logins: [GitHubLogin], to config: Config) -> Config {
        var updated = config
        let palette = ProfileColor.allCases
        for login in logins where !updated.githubAccounts.contains(where: {
            $0.host.caseInsensitiveCompare(login.host) == .orderedSame && $0.username.caseInsensitiveCompare(login.login) == .orderedSame
        }) {
            updated.githubAccounts.append(GitHubAccount(
                nickname: login.login,
                username: login.login,
                host: login.host,
                color: palette[updated.githubAccounts.count % palette.count]
            ))
        }
        return updated
    }

    // MARK: Claude accounts

    public static func updateClaudeAccount(_ account: ClaudeAccount, in config: Config) throws -> Config {
        var updated = config
        replaceOrAppend(&updated.claudeAccounts, account)
        return try validated(updated)
    }

    // MARK: API keys (value in the Keychain only)

    /// Validates first, then stores the secret; on a Keychain error nothing is saved.
    public static func addAPIKey(
        nickname: String,
        provider: APIProvider,
        envVar: String,
        secret: String,
        color: ProfileColor,
        to config: Config,
        keychain: any KeychainStore
    ) throws -> (Config, APIKeyAccount) {
        let value = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw EditorError.emptySecret }
        let account = APIKeyAccount(nickname: nickname.trimmingCharacters(in: .whitespaces), provider: provider, envVar: envVar, color: color)
        var updated = config
        updated.apiKeys.append(account)
        updated = try validated(updated)
        do {
            try keychain.setSecret(Data(value.utf8), account: account.keychainAccount)
        } catch {
            throw EditorError.keychain(String(describing: error))
        }
        return (updated, account)
    }

    public static func updateAPIKey(_ account: APIKeyAccount, in config: Config) throws -> Config {
        var updated = config
        replaceOrAppend(&updated.apiKeys, account)
        return try validated(updated)
    }

    public static func replaceSecret(of account: APIKeyAccount, with secret: String, keychain: any KeychainStore) throws {
        let value = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw EditorError.emptySecret }
        do {
            try keychain.setSecret(Data(value.utf8), account: account.keychainAccount)
        } catch {
            throw EditorError.keychain(String(describing: error))
        }
    }

    /// Removes the key, its Keychain item and its use in profiles.
    public static func removeAPIKey(_ id: UUID, from config: Config, keychain: any KeychainStore) throws -> Config {
        guard let account = config.apiKey(id) else { return config }
        do {
            try keychain.deleteItem(account: account.keychainAccount)
        } catch {
            throw EditorError.keychain(String(describing: error))
        }
        var updated = config
        updated.apiKeys.removeAll { $0.id == id }
        for index in updated.profiles.indices {
            updated.profiles[index].apiKeyIds.removeAll { $0 == id }
        }
        return updated
    }

    // MARK: Profiles

    public static func upsert(_ profile: Profile, in config: Config) throws -> Config {
        var updated = config
        replaceOrAppend(&updated.profiles, profile)
        return try validated(updated)
    }

    public static func removeProfile(_ id: UUID, from config: Config) -> Config {
        var updated = config
        updated.profiles.removeAll { $0.id == id }
        return updated
    }

    /// Sets the key used for one provider in a profile (one key per variable).
    public static func setAPIKey(_ keyId: UUID?, for provider: APIProvider, in profile: Profile, config: Config) -> Profile {
        var profile = profile
        profile.apiKeyIds.removeAll { config.apiKey($0)?.provider == provider }
        if let keyId { profile.apiKeyIds.append(keyId) }
        return profile
    }

    // MARK: Helpers

    static func replaceOrAppend<T: Identifiable>(_ list: inout [T], _ item: T) where T.ID == UUID {
        if let index = list.firstIndex(where: { $0.id == item.id }) { list[index] = item } else { list.append(item) }
    }

    static func validated(_ config: Config) throws -> Config {
        let issues = Validation.issues(in: config)
        guard issues.isEmpty else { throw EditorError.invalid(issues) }
        return config
    }
}
