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
            (profileId, override, touchesGitAndGitHub) = (previous.profileId, previous.claudeOverrideId, true)
        }

        let profile = config.profile(profileId)
        if profileId != nil, profile == nil { throw SwitchError.preflight(.profileNotFound) }
        if let override, config.claudeAccount(override) == nil { throw SwitchError.preflight(.claudeAccountNotFound) }

        // Override wins, then the profile's account, then whatever was applied last
        // (a profile without Claude does not switch Claude).
        let claudeAccount = config.claudeAccount(override ?? profile?.claudeAccountId ?? previous.appliedClaudeAccountId)
        let claudeTarget: ClaudeTarget = switch claudeAccount {
        case nil: .unchanged
        case let account?: account.configDir.map(ClaudeTarget.directory) ?? .defaultAccount
        }

        let now = environment.clock()
        let newState = ActiveState(
            profileId: profileId,
            claudeOverrideId: override,
            appliedClaudeAccountId: claudeAccount?.id,
            activatedAt: operation.startsNewActivation ? now : (previous.activatedAt ?? now),
            generation: previous.generation + 1
        )
        let apiKeys = (profile?.apiKeyIds ?? []).compactMap(config.apiKey)
        let shellEnvironment = ShellEnvironment(
            generation: newState.generation,
            managedVars: config.managedEnvVars,
            claude: claudeTarget,
            apiKeys: apiKeys.map { .init(envVar: $0.envVar, keychainAccount: $0.keychainAccount) }
        )
        let childEnvironment = environment.baseProcessEnvironment(path: await tools.searchDirectories())

        // Preflight: everything that can be checked without changing anything.
        var githubPlan: (cli: GitHubCLI, host: String, login: String, previous: String?)?
        if touchesGitAndGitHub, let account = config.githubAccount(profile?.githubAccountId) {
            guard let gh = await tools.locate(.gh) else { throw SwitchError.preflight(.toolMissing(.gh)) }
            let cli = GitHubCLI(runner: environment.runner, executable: gh, baseEnvironment: childEnvironment)
            let logins: [GitHubLogin]
            do {
                logins = try await cli.logins()
            } catch {
                throw SwitchError.preflight(.githubStatusUnavailable(String(describing: error)))
            }
            guard let login = logins.first(where: {
                $0.host.caseInsensitiveCompare(account.host) == .orderedSame
                    && $0.login.caseInsensitiveCompare(account.username) == .orderedSame
                    && $0.isUsable
            }) else {
                throw SwitchError.preflight(.githubAccountNotLoggedIn(host: account.host, user: account.username))
            }
            let active = logins.first { $0.host == login.host && $0.active }?.login
            githubPlan = (cli, login.host, login.login, active)
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

        // Steps.
        var steps: [SwitchStep] = []
        if touchesGitAndGitHub {
            steps.append(gitStep(GitConfigRenderer.render(config.gitIdentity(profile?.gitIdentityId), environment: environment)))
        }
        if let githubPlan {
            steps.append(githubStep(githubPlan.cli, host: githubPlan.host, login: githubPlan.login, previous: githubPlan.previous))
        }
        if claudeTarget != .unchanged {
            steps.append(launchdStep(claudeTarget, launchctl: Launchctl(runner: environment.runner, baseEnvironment: childEnvironment)))
        }
        steps.append(envFilesStep(shellEnvironment))
        steps.append(stateStep(newState))

        log?.log(.info, "switch \(transaction): start profile=\(profile?.name ?? "-") claude=\(String(describing: claudeTarget)) steps=\(steps.map(\.kind.rawValue))")
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

    private func githubStep(_ cli: GitHubCLI, host: String, login: String, previous: String?) -> SwitchStep {
        SwitchStep(kind: .github) {
            guard previous != login else { return {} }
            try await cli.switchAccount(host: host, user: login)
            return {
                if let previous { try await cli.switchAccount(host: host, user: previous) }
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
