import Foundation

/// What onboarding finds on the Mac (design 02b, step "Perfis").
public struct DetectedSetup: Equatable, Sendable {
    public struct ToolInfo: Equatable, Sendable {
        public let tool: Tool
        public let path: String?
        public let version: String?
    }

    public struct ClaudeFolder: Equatable, Sendable {
        /// nil = default `~/.claude`.
        public let configDir: String?
        public let status: ClaudeLoginStatus?
    }

    public var tools: [ToolInfo] = []
    public var gitName: String?
    public var gitEmail: String?
    public var githubLogins: [GitHubLogin] = []
    public var claudeFolders: [ClaudeFolder] = []
    public var legacyProfiles: [LegacyMigration.LegacyProfile] = []
    public var legacyActiveKey: String?
    public var legacyFindings: [LegacyMigration.Finding] = []

    public var hasLegacyInstall: Bool { !legacyFindings.isEmpty || !legacyProfiles.isEmpty }
}

public struct SetupDetector: Sendable {
    let environment: SystemEnvironment
    let tools: any ToolLocating

    public init(environment: SystemEnvironment, tools: any ToolLocating) {
        self.environment = environment
        self.tools = tools
    }

    public func detect() async -> DetectedSetup {
        var setup = DetectedSetup()
        let path = await tools.searchDirectories()
        let env = environment.baseProcessEnvironment(path: path)

        for tool in Tool.allCases {
            let url = await tools.locate(tool)
            var version: String?
            if let url {
                let result = try? await environment.runner.run(CommandRequest(executable: url, arguments: ["--version"], environment: env, timeout: .seconds(10)))
                version = result.flatMap { $0.succeeded ? $0.stdout.split(whereSeparator: \.isNewline).first.map(String.init) : nil }
            }
            setup.tools.append(.init(tool: tool, path: url?.path, version: version))
        }

        if let git = await tools.locate(.git) {
            func value(_ key: String) async -> String? {
                let result = try? await environment.runner.run(CommandRequest(
                    executable: git,
                    arguments: ["config", "--global", "--includes", "--get", key],
                    environment: env,
                    currentDirectory: environment.home,
                    timeout: .seconds(10)
                ))
                let text = result?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return result?.succeeded == true && !text.isEmpty ? text : nil
            }
            setup.gitName = await value("user.name")
            setup.gitEmail = await value("user.email")
        }

        if let gh = await tools.locate(.gh) {
            setup.githubLogins = (try? await GitHubCLI(runner: environment.runner, executable: gh, baseEnvironment: env).logins()) ?? []
        }

        setup.claudeFolders = claudeFolders()
        setup.legacyProfiles = LegacyMigration.importProfiles(environment: environment)
        setup.legacyActiveKey = LegacyMigration.activeProfileKey(environment: environment)
        setup.legacyFindings = LegacyMigration.findings(environment: environment)
        return setup
    }

    /// `~/.claude` and `~/.claude-*` folders.
    func claudeFolders() -> [DetectedSetup.ClaudeFolder] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: environment.home.path)) ?? []
        return names
            .filter { $0 == ".claude" || $0.hasPrefix(".claude-") }
            .sorted()
            .compactMap { name in
                let url = environment.home.appendingPathComponent(name, isDirectory: true)
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
                let configDir = name == ".claude" ? nil : ClaudePaths.standardize(url.path)
                let account = ClaudeAccount(nickname: name, color: .graphite, configDir: configDir)
                return .init(configDir: configDir, status: ClaudeAccountFiles.statusFromStateFile(for: account, environment: environment))
            }
    }

    /// Accounts and profiles to propose, plus the profile to activate first.
    /// The legacy perfis.conf wins when present; otherwise one profile is built
    /// from the current global git identity, the active gh account and ~/.claude.
    public static func suggestedConfig(from setup: DetectedSetup, environment: SystemEnvironment) -> (Config, UUID?) {
        var config = Config()
        let palette: [ProfileColor] = [.indigo, .orange, .teal, .green, .blue, .pink, .red, .graphite]
        // Claude folders go on the profiles (config v2); Claude accounts (tokens)
        // are added later by the user, so none are suggested here.

        func githubAccount(_ username: String, host: String = "github.com", nickname: String) -> UUID {
            if let existing = config.githubAccounts.first(where: { $0.username.caseInsensitiveCompare(username) == .orderedSame && $0.host == host }) {
                return existing.id
            }
            let spelled = setup.githubLogins.first { $0.login.caseInsensitiveCompare(username) == .orderedSame }?.login ?? username
            let account = GitHubAccount(nickname: nickname, username: spelled, host: host, color: palette[config.githubAccounts.count % palette.count])
            config.githubAccounts.append(account)
            return account.id
        }

        var initial: UUID?
        if !setup.legacyProfiles.isEmpty {
            for (index, legacy) in setup.legacyProfiles.enumerated() {
                let color = palette[index % palette.count]
                var gitId: UUID?
                if let email = legacy.gitEmail {
                    let identity = GitIdentity(nickname: legacy.displayName, name: legacy.gitName ?? email, email: email, sshKeyPath: legacy.sshKey, color: color)
                    config.gitIdentities.append(identity)
                    gitId = identity.id
                }
                let ghId = legacy.githubUser.map { githubAccount($0, nickname: legacy.displayName) }
                let profile = Profile(name: legacy.displayName, color: color, gitIdentityId: gitId, githubAccountId: ghId, claudeConfigDir: legacy.claudeDir)
                config.profiles.append(profile)
                if legacy.key == setup.legacyActiveKey { initial = profile.id }
            }
        } else {
            var gitId: UUID?
            if let email = setup.gitEmail {
                let identity = GitIdentity(nickname: "Principal", name: setup.gitName ?? email, email: email, color: .indigo)
                config.gitIdentities.append(identity)
                gitId = identity.id
            }
            let active = setup.githubLogins.first { $0.active }
            let ghId = active.map { githubAccount($0.login, host: $0.host, nickname: $0.login) }
            let profile = Profile(name: "Principal", color: .indigo, gitIdentityId: gitId, githubAccountId: ghId, claudeConfigDir: nil)
            config.profiles.append(profile)
            initial = profile.id
        }

        // Every gh login becomes an account the user can pick later.
        for login in setup.githubLogins { _ = githubAccount(login.login, host: login.host, nickname: login.login) }
        return (config, initial ?? config.profiles.first?.id)
    }
}
