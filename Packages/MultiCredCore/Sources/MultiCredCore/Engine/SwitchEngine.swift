import Foundation

/// Applies profiles transactionally (docs/PLAN.md §5.2).
///
/// ```
///  preflight (no changes) ─► git ─► github ─► launchd ─► envFiles ─► state
///                                                                    ▲ commit point:
///                                                                    │ generation bump
///  failure at step k ⇒ undo k-1 … 1 in reverse order, report the step and
///  whether the rollback was complete.
/// ```
///
/// An actor: one switch at a time. A second request while one runs gets
/// `SwitchError.busy` instead of queueing behind it.
public actor SwitchEngine {
    public static let claudeVariable = "CLAUDE_CONFIG_DIR"

    private let environment: SystemEnvironment
    private let paths: AppPaths
    private let tools: any ToolLocating
    private let stateStore: StateStore
    private let log: EventLog?
    private let securityTool: String
    private var isSwitching = false

    public init(
        environment: SystemEnvironment,
        tools: any ToolLocating,
        log: EventLog? = nil,
        securityTool: String = EnvFileRenderer.securityTool
    ) {
        self.environment = environment
        self.paths = AppPaths(environment: environment)
        self.tools = tools
        self.stateStore = StateStore(paths: AppPaths(environment: environment), clock: environment.clock)
        self.log = log
        self.securityTool = securityTool
    }

    /// Switches everything to `profileId` and clears any Claude-only override.
    public func switchProfile(_ profileId: UUID, in config: Config) async throws -> SwitchResult {
        try await perform(config: config, operation: .profile(profileId))
    }

    /// Switches only the Claude Code account; git, gh and API keys stay.
    /// Pass nil to go back to the active profile's own Claude account.
    public func switchClaudeOnly(to accountId: UUID?, in config: Config) async throws -> SwitchResult {
        try await perform(config: config, operation: .claudeOnly(accountId))
    }

    /// Re-applies the active profile (at login, since launchd forgets on reboot).
    /// Returns nil when no profile was ever activated.
    public func reapplyActiveProfile(in config: Config) async throws -> SwitchResult? {
        let state = try loadState()
        guard state.profileId != nil else { return nil }
        return try await perform(config: config, operation: .reapply)
    }

    public func currentState() throws -> ActiveState {
        try loadState()
    }

    // MARK: - Transaction

    private enum Operation {
        case profile(UUID)
        case claudeOnly(UUID?)
        case reapply

        /// "Active since" restarts only when a profile is chosen.
        var startsNewActivation: Bool {
            if case .profile = self { return true }
            return false
        }
    }

    private func perform(config: Config, operation: Operation) async throws -> SwitchResult {
        guard !isSwitching else { throw SwitchError.busy }
        isSwitching = true
        defer { isSwitching = false }

        let transaction = String(UUID().uuidString.prefix(8))
        let issues = Validation.issues(in: config)
        guard issues.isEmpty else {
            log?.log(.error, "switch \(transaction): invalid configuration (\(issues.count) issues)")
            throw SwitchError.invalidConfiguration(issues)
        }
        let previous = try loadState()

        let profileId: UUID?
        let override: UUID?
        let touchesGitAndGitHub: Bool
        switch operation {
        case let .profile(id):
            (profileId, override, touchesGitAndGitHub) = (id, nil, true)
        case let .claudeOnly(accountId):
            (profileId, override, touchesGitAndGitHub) = (previous.profileId, accountId, false)
        case .reapply:
            // An override for an account that no longer exists (e.g. a v1
            // folder account removed by the migration) is dropped, not fatal.
            let kept = previous.claudeOverrideId.flatMap { id in
                id == ClaudeFolder.ownLoginOverride || config.claudeAccount(id) != nil ? id : nil
            }
            (profileId, override, touchesGitAndGitHub) = (previous.profileId, kept, true)
        }

        let profile = config.profile(profileId)
        if profileId != nil, profile == nil { throw SwitchError.preflight(.profileNotFound) }
        if let override, override != ClaudeFolder.ownLoginOverride, config.claudeAccount(override) == nil {
            throw SwitchError.preflight(.claudeAccountNotFound)
        }

        // The Claude folder (agents, skills, chats) belongs to the profile and only
        // changes with the profile. The Claude account is just the credential:
        // the override (switch only the Claude account) wins over the profile's
        // choice, and no account means the folder's own login.
        let claudeTarget: ClaudeTarget = profile.map { $0.claudeConfigDir.map(ClaudeTarget.directory) ?? .defaultAccount } ?? .unchanged
        let chosen = override == ClaudeFolder.ownLoginOverride ? nil : (override ?? profile?.claudeAccountId)
        let tokenAccount = config.claudeAccount(chosen).flatMap { $0.kind == .token ? $0 : nil }

        let now = environment.clock()
        let newState = ActiveState(
            profileId: profileId,
            claudeOverrideId: override,
            appliedClaudeAccountId: tokenAccount?.id,
            activatedAt: operation.startsNewActivation ? now : (previous.activatedAt ?? now),
            generation: previous.generation + 1
        )
        let apiKeys = (profile?.apiKeyIds ?? []).compactMap(config.apiKey)
        var exports = apiKeys.map { ShellEnvironment.APIKeyExport(envVar: $0.envVar, keychainAccount: $0.keychainAccount) }
        if let tokenAccount {
            exports.append(.init(envVar: ClaudeFolder.tokenVariable, keychainAccount: tokenAccount.keychainAccount))
        }
        let shellEnvironment = ShellEnvironment(
            generation: newState.generation,
            managedVars: config.managedEnvVars,
            claude: claudeTarget,
            apiKeys: exports
        )
        let childEnvironment = environment.baseProcessEnvironment(path: await tools.searchDirectories())

        // Preflight: everything that can be checked without changing anything.
        // gh token validity is deliberately not checked here: `gh auth status`
        // tests every token over the network, which would make switching slow and
        // impossible offline. An account gh does not know makes `gh auth switch`
        // fail, and the transaction rolls back. Token health belongs to Verify.
        var githubPlan: (cli: GitHubCLI, account: GitHubAccount)?
        if touchesGitAndGitHub, let account = config.githubAccount(profile?.githubAccountId) {
            guard let gh = await tools.locate(.gh) else { throw SwitchError.preflight(.toolMissing(.gh)) }
            githubPlan = (GitHubCLI(runner: environment.runner, executable: gh, baseEnvironment: childEnvironment), account)
        }
        if case let .directory(directory) = claudeTarget {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw SwitchError.preflight(.claudeDirectoryMissing(directory))
            }
        }
        for key in apiKeys {
            let present: Bool
            do {
                present = try environment.keychain.containsItem(account: key.keychainAccount)
            } catch {
                throw SwitchError.preflight(.keychainUnavailable(String(describing: error)))
            }
            guard present else { throw SwitchError.preflight(.apiKeyMissing(nickname: key.nickname, envVar: key.envVar)) }
        }
        if let tokenAccount {
            let present = (try? environment.keychain.containsItem(account: tokenAccount.keychainAccount)) ?? false
            guard present else { throw SwitchError.preflight(.claudeTokenMissing(tokenAccount.nickname)) }
            if (try? environment.keychain.isLegacyItem(account: tokenAccount.keychainAccount)) == true {
                throw SwitchError.preflight(.claudeTokenNeedsRefresh(tokenAccount.nickname))
            }
        }

        // Steps.
        var steps: [SwitchStep] = []
        if touchesGitAndGitHub {
            steps.append(gitStep(GitConfigRenderer.render(config.gitIdentity(profile?.gitIdentityId), environment: environment)))
        }
        if let githubPlan {
            steps.append(githubStep(githubPlan.cli, account: githubPlan.account))
        }
        // Switching only the Claude account never moves the folder.
        if touchesGitAndGitHub, claudeTarget != .unchanged {
            steps.append(launchdStep(claudeTarget, launchctl: Launchctl(runner: environment.runner, baseEnvironment: childEnvironment)))
        }
        // Claude as co-author follows the profile's GitHub account, written to
        // the profile's Claude folder (Claude Code reads it only from settings).
        if touchesGitAndGitHub, let profile, let github = config.githubAccount(profile.githubAccountId) {
            steps.append(claudeSettingsStep(configDir: profile.claudeConfigDir, coAuthor: github.claudeCoAuthor))
        }
        steps.append(envFilesStep(shellEnvironment))
        steps.append(stateStep(newState))

        log?.log(.info, "switch \(transaction): start profile=\(profile?.name ?? "-") folder=\(String(describing: claudeTarget)) account=\(tokenAccount?.nickname ?? "login da pasta") steps=\(steps.map(\.kind.rawValue))")
        var undoStack: [(SwitchStepKind, SwitchStep.Undo)] = []
        for step in steps {
            do {
                let undo = try await step.apply()
                undoStack.append((step.kind, undo))
            } catch {
                let reason = String(describing: error)
                log?.log(.error, "switch \(transaction): step \(step.kind.rawValue) failed: \(reason)")
                var notUndone: [SwitchStepKind] = []
                for (kind, undo) in undoStack.reversed() {
                    do {
                        try await undo()
                    } catch {
                        notUndone.append(kind)
                        log?.log(.error, "switch \(transaction): rollback of \(kind.rawValue) failed: \(error)")
                    }
                }
                let outcome: RollbackOutcome = notUndone.isEmpty ? .complete : .incomplete(failed: notUndone)
                throw SwitchError.stepFailed(step: step.kind, reason: reason, rollback: outcome)
            }
        }
        log?.log(.info, "switch \(transaction): done generation=\(newState.generation)")
        return SwitchResult(state: newState, claudeTarget: claudeTarget, appliedSteps: steps.map(\.kind))
    }

    private func loadState() throws -> ActiveState {
        do {
            return try stateStore.load()
        } catch {
            throw SwitchError.stateUnreadable(String(describing: error))
        }
    }

    // MARK: - Steps

    private func gitStep(_ content: String) -> SwitchStep {
        let url = paths.gitconfig
        return SwitchStep(kind: .git) {
            let previous = try? Data(contentsOf: url)
            try AtomicFileWriter.write(Data(content.utf8), to: url, permissions: 0o644)
            return { try FileRestore.restore(previous, to: url) }
        }
    }

    private func githubStep(_ cli: GitHubCLI, account: GitHubAccount) -> SwitchStep {
        SwitchStep(kind: .github) {
            let previous = try await cli.activeLogin(host: account.host)
            if let previous, previous.caseInsensitiveCompare(account.username) == .orderedSame { return {} }
            try await cli.switchAccount(host: account.host, user: account.username)
            return {
                if let previous { try await cli.switchAccount(host: account.host, user: previous) }
            }
        }
    }

    private func launchdStep(_ target: ClaudeTarget, launchctl: Launchctl) -> SwitchStep {
        let desired: String? = if case let .directory(path) = target { path } else { nil }
        return SwitchStep(kind: .launchd) {
            let previous = try await launchctl.getenv(Self.claudeVariable)
            guard previous != desired else { return {} }
            try await launchctl.apply(Self.claudeVariable, desired)
            return { try await launchctl.apply(Self.claudeVariable, previous) }
        }
    }

    private func claudeSettingsStep(configDir: String?, coAuthor: Bool) -> SwitchStep {
        let url = ClaudeAttribution.settingsFile(configDir: configDir, environment: environment)
        let log = self.log
        return SwitchStep(kind: .claudeSettings) {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path, isDirectory: &isDirectory), isDirectory.boolValue else {
                return {}
            }
            let target = try AtomicFileWriter.resolveTarget(url, followSymlink: true)
            let previous = try? Data(contentsOf: target)
            let next: Data?
            do {
                next = try ClaudeAttribution.updated(previous, coAuthor: coAuthor)
            } catch {
                // A settings.json MultiCred cannot parse is left untouched.
                log?.log(.warning, "claude settings not changed (unreadable): \(target.path)")
                return {}
            }
            guard let next else { return {} }
            // One backup of the user's original file, kept next to it.
            let backup = target.appendingPathExtension("multicred-backup")
            if let previous, !FileManager.default.fileExists(atPath: backup.path) {
                try AtomicFileWriter.write(previous, to: backup, permissions: 0o600)
            }
            try AtomicFileWriter.write(next, to: url, permissions: 0o644, followSymlink: true)
            return { try FileRestore.restore(previous, to: target) }
        }
    }

    private func envFilesStep(_ shellEnvironment: ShellEnvironment) -> SwitchStep {
        let (sh, fish) = (paths.envSh, paths.envFish)
        let posix = EnvFileRenderer.renderPOSIX(shellEnvironment, securityTool: securityTool)
        let fishText = EnvFileRenderer.renderFish(shellEnvironment, securityTool: securityTool)
        return SwitchStep(kind: .envFiles) {
            let previousSh = try? Data(contentsOf: sh)
            let previousFish = try? Data(contentsOf: fish)
            try AtomicFileWriter.write(Data(posix.utf8), to: sh, permissions: 0o644)
            do {
                try AtomicFileWriter.write(Data(fishText.utf8), to: fish, permissions: 0o644)
            } catch {
                try? FileRestore.restore(previousSh, to: sh)
                throw error
            }
            return {
                try FileRestore.restore(previousFish, to: fish)
                try FileRestore.restore(previousSh, to: sh)
            }
        }
    }

    private func stateStep(_ newState: ActiveState) -> SwitchStep {
        let store = stateStore
        return SwitchStep(kind: .state) {
            let snapshot = store.snapshot()
            do {
                try store.commit(newState)
            } catch {
                try? store.restore(snapshot)
                throw error
            }
            return { try store.restore(snapshot) }
        }
    }
}
