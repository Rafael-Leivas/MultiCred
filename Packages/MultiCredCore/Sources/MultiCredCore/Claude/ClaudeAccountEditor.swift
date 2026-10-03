import Foundation

/// Where a new Claude account keeps its configuration.
public enum ClaudeFolderChoice: Equatable, Sendable {
    /// `~/.claude`, used with `CLAUDE_CONFIG_DIR` unset.
    case defaultFolder
    /// A folder that already exists (an account the user set up before).
    case existing(String)
    /// A folder MultiCred creates now (0700).
    case new(String)
}

public enum ClaudeAccountError: Error, Equatable, Sendable {
    case invalidPath(String)
    case folderAlreadyUsed(by: String)
    case folderMissing(String)
    case notADirectory(String)
    /// In test mode every account folder must live inside the sandbox home.
    case outsideSandbox(String)
    case createFailed(String)
    case invalid([ValidationIssue])
}

/// Adds and removes Claude accounts in a `Config`. Pure apart from creating the
/// folder for `.new`; the caller saves the returned config.
public enum ClaudeAccountEditor {
    public static func add(
        nickname: String,
        email: String? = nil,
        color: ProfileColor,
        folder: ClaudeFolderChoice,
        to config: Config,
        environment: SystemEnvironment
    ) throws -> (Config, ClaudeAccount) {
        let configDir: String?
        switch folder {
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
        if let owner = config.claudeAccounts.first(where: { $0.configDir == configDir }) {
            throw ClaudeAccountError.folderAlreadyUsed(by: owner.nickname)
        }

        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory)
        if exists, !isDirectory.boolValue { throw ClaudeAccountError.notADirectory(directory) }
        switch folder {
        case .existing where !exists:
            throw ClaudeAccountError.folderMissing(directory)
        case .new where !exists, .defaultFolder where !exists:
            do {
                try FileManager.default.createDirectory(
                    atPath: directory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            } catch {
                throw ClaudeAccountError.createFailed(error.localizedDescription)
            }
        default:
            break
        }

        let account = ClaudeAccount(
            nickname: nickname.trimmingCharacters(in: .whitespaces),
            email: email,
            color: color,
            configDir: configDir
        )
        var updated = config
        updated.claudeAccounts.append(account)
        let issues = Validation.issues(in: updated)
        guard issues.isEmpty else { throw ClaudeAccountError.invalid(issues) }
        return (updated, account)
    }

    /// Removes the account from the configuration and from every profile that
    /// used it (those profiles stop switching Claude). The folder and the
    /// login are left untouched.
    public static func remove(_ accountId: UUID, from config: Config) -> Config {
        var updated = config
        updated.claudeAccounts.removeAll { $0.id == accountId }
        for index in updated.profiles.indices where updated.profiles[index].claudeAccountId == accountId {
            updated.profiles[index].claudeAccountId = nil
        }
        return updated
    }

    /// Profiles that use the account ("Usada em" in design 03).
    public static func profilesUsing(_ accountId: UUID, in config: Config) -> [Profile] {
        config.profiles.filter { $0.claudeAccountId == accountId }
    }
}
