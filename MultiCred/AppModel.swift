import Foundation
import MultiCredCore
import Observation
import ServiceManagement

/// What the HUD and notification show after a switch.
struct SwitchOutcome {
    let profile: Profile?
    let claudeAccount: ClaudeAccount?
    let steps: [SwitchStepKind]
    /// Claude Code processes running right after the switch; they keep the
    /// account they were started with.
    let runningClaudeSessions: Int
    let claudeOnly: Bool
}

/// Overall state for the menu pill.
enum Consistency: Equatable {
    case unknown
    case ok
    case problems(count: Int, first: String)
}

/// App-wide state on the main actor. Owns the configuration, the switch
/// engine, statuses and verification; views read it and call its methods.
@MainActor
@Observable
final class AppModel {
    let environment: SystemEnvironment
    let tools: ToolLocator
    let log: EventLog
    let claudeLoginMode: ClaudeLoginMode
    /// Finds the `claude` used for login and logout.
    let claudeLocator: ToolLocator
    @ObservationIgnored let sandboxRunner: SandboxCommandRunner?
    @ObservationIgnored private let repository: ConfigRepository
    @ObservationIgnored private let engine: SwitchEngine
    @ObservationIgnored private let statusService: ClaudeStatusService
    @ObservationIgnored let processScanner: any ProcessScanning = SystemProcessScanner()

    private(set) var config = Config()
    private(set) var state = ActiveState()
    private(set) var isInstalled = false
    private(set) var claudeStatuses: [UUID: ClaudeLoginStatus] = [:]
    private(set) var githubLogins: [GitHubLogin] = []
    private(set) var isSwitching = false
    private(set) var verification: VerificationReport?
    private(set) var isVerifying = false
    /// Last user-facing problem, shown by the window that triggered it.
    var lastError: String?
    /// Called after every successful switch (HUD, notification, icon).
    @ObservationIgnored var onSwitched: ((SwitchOutcome) -> Void)?

    init(runtime: AppRuntime.Runtime) {
        environment = runtime.environment
        sandboxRunner = runtime.sandboxRunner
        let directories = environment.mode == .real ? ToolLocator.defaultSearchDirectories : AppRuntime.realToolDirectories
        tools = ToolLocator(environment: environment, wellKnownDirectories: directories)
        claudeLocator = tools
        log = EventLog(directory: environment.logsDirectory)
        claudeLoginMode = AppRuntime.claudeLoginMode(for: environment)
        repository = ConfigRepository(environment: environment)
        engine = SwitchEngine(environment: environment, tools: tools, log: log)
        statusService = ClaudeStatusService(environment: environment, tools: tools)
    }

    var isTestMode: Bool { environment.mode != .real }

    func load() async {
        do {
            config = try repository.load() ?? Config()
            state = try await engine.currentState()
        } catch {
            lastError = UserMessages.describe(error)
            log.log(.error, "load failed: \(error)")
        }
        isInstalled = Installer(environment: environment).manifest() != nil
    }

    // MARK: Derived

    var activeProfile: Profile? { config.profile(state.profileId) }
    var appliedClaudeAccount: ClaudeAccount? { config.claudeAccount(state.appliedClaudeAccountId) }

    var consistency: Consistency {
        guard let verification else { return .unknown }
        guard let first = verification.problems.first else { return .ok }
        return .problems(count: verification.problems.count, first: first.title)
    }

    func claudeStatus(_ account: ClaudeAccount) -> ClaudeLoginStatus? { claudeStatuses[account.id] }

    /// A profile cannot really be used while its Claude account needs a login.
    func needsClaudeLogin(_ profile: Profile) -> Bool {
        guard let account = config.claudeAccount(profile.claudeAccountId) else { return false }
        return claudeStatuses[account.id] == .loggedOut
    }

    func githubLogin(for account: GitHubAccount) -> GitHubLogin? {
        githubLogins.first { $0.host == account.host && $0.login.caseInsensitiveCompare(account.username) == .orderedSame }
    }

    // MARK: Switching

    @discardableResult
    func switchProfile(_ id: UUID) async -> String? {
        await performSwitch(claudeOnly: false) { try await self.engine.switchProfile(id, in: self.config) }
    }

    @discardableResult
    func switchClaudeOnly(to accountId: UUID?) async -> String? {
        await performSwitch(claudeOnly: true) { try await self.engine.switchClaudeOnly(to: accountId, in: self.config) }
    }

    /// At launch: launchd forgets on reboot, so the active profile is applied again.
    func reapplyActiveProfile() async {
        guard isInstalled else { return }
        do {
            if let result = try await engine.reapplyActiveProfile(in: config) {
                state = result.state
                log.log(.info, "reapplied active profile at launch")
            }
        } catch {
            lastError = UserMessages.describe(error)
            log.log(.error, "reapply failed: \(error)")
        }
        await verify(checkTokens: false)
    }

    private func performSwitch(claudeOnly: Bool, _ operation: () async throws -> SwitchResult) async -> String? {
        guard !isSwitching else { return UserMessages.busy }
        isSwitching = true
        defer { isSwitching = false }
        do {
            let result = try await operation()
            state = result.state
            onSwitched?(SwitchOutcome(
                profile: activeProfile,
                claudeAccount: appliedClaudeAccount,
                steps: result.appliedSteps,
                runningClaudeSessions: processScanner.countProcesses(named: "claude"),
                claudeOnly: claudeOnly
            ))
            Task { await verify(checkTokens: false) }
            return nil
        } catch {
            let message = UserMessages.describe(error)
            lastError = message
            Task { await verify(checkTokens: false) }
            return message
        }
    }

    // MARK: Editing

    /// Applies an edit, validates and saves it. Returns false and sets `lastError` on failure.
    @discardableResult
    func edit(_ change: (Config) throws -> Config) -> Bool {
        do {
            let updated = try change(config)
            try repository.save(updated)
            config = updated
            return true
        } catch {
            lastError = UserMessages.describe(error)
            return false
        }
    }

    func addAPIKey(nickname: String, provider: APIProvider, envVar: String, secret: String, color: ProfileColor) -> APIKeyAccount? {
        var created: APIKeyAccount?
        edit { config in
            let (updated, key) = try ConfigEditor.addAPIKey(
                nickname: nickname, provider: provider, envVar: envVar, secret: secret,
                color: color, to: config, keychain: environment.keychain
            )
            created = key
            return updated
        }
        return created
    }

    func replaceSecret(of key: APIKeyAccount, with secret: String) -> Bool {
        do {
            try ConfigEditor.replaceSecret(of: key, with: secret, keychain: environment.keychain)
            return true
        } catch {
            lastError = UserMessages.describe(error)
            return false
        }
    }

    func hasSecret(_ key: APIKeyAccount) -> Bool {
        (try? environment.keychain.containsItem(account: key.keychainAccount)) ?? false
    }

    // MARK: Claude accounts

    func refreshClaudeStatuses(force: Bool = false) async {
        for account in config.claudeAccounts {
            await refreshClaudeStatus(account.id, force: force)
        }
    }

    func refreshClaudeStatus(_ accountId: UUID, force: Bool = true) async {
        guard let account = config.claudeAccount(accountId) else { return }
        if force { await statusService.invalidate(accountId) }
        let status = await statusService.status(for: account)
        claudeStatuses[accountId] = status
        if case let .loggedIn(email?) = status, account.email != email {
            var updated = account
            updated.email = email
            edit { try ConfigEditor.updateClaudeAccount(updated, in: $0) }
        }
    }

    @discardableResult
    func addClaudeAccount(nickname: String, color: ProfileColor, folder: ClaudeFolderChoice) -> ClaudeAccount? {
        do {
            let (updated, account) = try ClaudeAccountEditor.add(
                nickname: nickname, color: color, folder: folder, to: config, environment: environment
            )
            try repository.save(updated)
            config = updated
            log.log(.info, "claude account added: \(account.nickname) dir=\(account.configDir.map(environment.abbreviate) ?? "default")")
            return account
        } catch {
            lastError = UserMessages.describe(error)
            return nil
        }
    }

    func removeClaudeAccount(_ accountId: UUID) {
        if edit({ ClaudeAccountEditor.remove(accountId, from: $0) }) {
            claudeStatuses[accountId] = nil
        }
    }

    func profilesUsing(claudeAccount accountId: UUID) -> [Profile] {
        config.profiles.filter { $0.claudeAccountId == accountId }
    }

    /// `claude auth logout` for one folder (or clears the simulated state file).
    func logoutClaudeAccount(_ accountId: UUID) async -> String? {
        guard let account = config.claudeAccount(accountId) else { return nil }
        defer { Task { await refreshClaudeStatus(accountId) } }

        switch claudeLoginMode {
        case .simulated:
            let file = ClaudeAccountFiles.stateFile(for: account, environment: environment)
            guard file.path.hasPrefix(environment.home.path + "/") else { return nil }
            try? FileManager.default.removeItem(at: file)
            return nil
        case .realInSandbox, .real:
            if claudeLoginMode == .realInSandbox, account.isDefault {
                return UserMessages.defaultAccountInTestMode
            }
            guard let claude = await claudeLocator.locate(.claude) else {
                return LoginLaunchError.claudeNotInstalled.message
            }
            // In test mode the shared runner is simulated; logout must really run.
            let runner: any CommandRunner = claudeLoginMode == .real ? environment.runner : ProcessRunner()
            let cli = ClaudeCLI(runner: runner, executable: claude, baseEnvironment: environment.baseProcessEnvironment(path: await tools.searchDirectories()))
            do {
                try await cli.logout(account)
                log.log(.info, "claude logout for \(account.nickname)")
                return nil
            } catch {
                return UserMessages.describe(error)
            }
        }
    }

    // MARK: GitHub

    func githubCLI() async -> GitHubCLI? {
        guard let gh = await tools.locate(.gh) else { return nil }
        return GitHubCLI(runner: environment.runner, executable: gh, baseEnvironment: environment.baseProcessEnvironment(path: await tools.searchDirectories()))
    }

    /// Accounts gh knows (network: gh checks each token).
    func refreshGitHubLogins() async {
        guard let cli = await githubCLI() else { return }
        do {
            githubLogins = try await cli.logins()
        } catch {
            log.log(.warning, "gh logins: \(error)")
        }
    }

    /// After `gh auth login`: record the new account and give gh back to the
    /// active profile (gh makes the new login active).
    func didLogInToGitHub(_ login: String?) async {
        if let login, let sandboxRunner { await sandboxRunner.addGitHubLogin(login) }
        await refreshGitHubLogins()
        edit { ConfigEditor.addMissingGitHubAccounts(githubLogins, to: $0) }
        if let account = config.githubAccount(activeProfile?.githubAccountId), let cli = await githubCLI() {
            try? await cli.switchAccount(host: account.host, user: account.username)
        }
        await verify(checkTokens: false)
    }

    // MARK: Verify

    func verify(checkTokens: Bool) async {
        guard isInstalled, !isVerifying else { return }
        isVerifying = true
        defer { isVerifying = false }
        let service = statusService
        verification = await Verifier(environment: environment, tools: tools, processes: processScanner)
            .run(config: config, state: state, checkGitHubTokens: checkTokens) { account in
                await service.status(for: account)
            }
    }

    enum FixResult {
        case done
        case failed(String)
        case openClaudeLogin(UUID)
        case openGitHubLogin(String)
        case openAPIKey(UUID)
    }

    func apply(_ fix: Fix) async -> FixResult {
        log.log(.info, "fix: \(fix)")
        let result: FixResult
        switch fix {
        case .reapplyProfile:
            if let id = state.profileId {
                let error: String? = if let override = state.claudeOverrideId {
                    await switchProfileThenOverride(id, override)
                } else {
                    await switchProfile(id)
                }
                result = error.map(FixResult.failed) ?? .done
            } else {
                result = .failed("Nenhum perfil ativo.")
            }
        case .reinstallIntegration:
            result = reinstallIntegration(removeLegacy: false).map(FixResult.failed) ?? .done
        case .removeLegacy:
            result = reinstallIntegration(removeLegacy: true).map(FixResult.failed) ?? .done
        case let .switchGitHub(host, user):
            if let cli = await githubCLI() {
                do {
                    try await cli.switchAccount(host: host, user: user)
                    result = .done
                } catch {
                    result = .failed(UserMessages.describe(error))
                }
            } else {
                result = .failed(UserMessages.describe(PreflightFailure.toolMissing(.gh)))
            }
        case let .loginClaude(id): result = .openClaudeLogin(id)
        case let .loginGitHub(host): result = .openGitHubLogin(host)
        case let .setAPIKeySecret(id): result = .openAPIKey(id)
        }
        await verify(checkTokens: false)
        return result
    }

    private func switchProfileThenOverride(_ profile: UUID, _ override: UUID) async -> String? {
        if let error = await switchProfile(profile) { return error }
        return await switchClaudeOnly(to: override)
    }

    func fixAll() async -> [String] {
        var errors: [String] = []
        let fixes = (verification?.problems.compactMap(\.fix) ?? [])
        var seen: [Fix] = []
        for fix in fixes where !seen.contains(fix) {
            seen.append(fix)
            if case let .failed(message) = await apply(fix) { errors.append(message) }
        }
        return errors
    }

    // MARK: Install / uninstall

    func detectSetup() async -> DetectedSetup {
        await SetupDetector(environment: environment, tools: tools).detect()
    }

    func previewInstall(_ options: InstallOptions) -> Result<[FileChange], UserFacingError> {
        do {
            return .success(try Installer(environment: environment).preview(options))
        } catch {
            return .failure(UserFacingError(text: UserMessages.describe(error)))
        }
    }

    /// Onboarding's last step: save the configuration, install, activate.
    func completeOnboarding(config newConfig: Config, options: InstallOptions, initialProfile: UUID?, openAtLogin: Bool) async -> String? {
        var configToSave = newConfig
        configToSave.settings.enabledShells = options.shells
        configToSave.settings.openAtLogin = openAtLogin
        do {
            try repository.save(configToSave)
            config = configToSave
            try Installer(environment: environment).apply(options)
            isInstalled = true
        } catch {
            return UserMessages.describe(error)
        }
        setOpenAtLogin(openAtLogin)
        if let initialProfile, let error = await switchProfile(initialProfile) {
            return error
        }
        await refreshClaudeStatuses(force: true)
        return nil
    }

    private func reinstallIntegration(removeLegacy: Bool) -> String? {
        do {
            try Installer(environment: environment).apply(InstallOptions(shells: config.settings.enabledShells, removeLegacy: removeLegacy))
            return nil
        } catch {
            return UserMessages.describe(error)
        }
    }

    func uninstallPreview() -> [FileChange] {
        Uninstaller(environment: environment).preview()
    }

    func uninstall(logoutCreatedClaudeAccounts: Bool) async -> UninstallReport {
        var extraProblems: [String] = []
        if logoutCreatedClaudeAccounts {
            for account in config.claudeAccounts where account.configDir != nil {
                if let error = await logoutClaudeAccount(account.id) { extraProblems.append(error) }
            }
        }
        var report = await Uninstaller(environment: environment).apply()
        report.problems += extraProblems
        setOpenAtLogin(false)
        isInstalled = false
        config = Config()
        state = ActiveState()
        verification = nil
        log.log(.info, "uninstalled: \(report.changedFiles)")
        return report
    }

    // MARK: Settings

    func updateSettings(_ settings: Settings) {
        let previous = config.settings
        guard edit({ config in
            var updated = config
            updated.settings = settings
            return updated
        }) else { return }
        if previous.enabledShells != settings.enabledShells, isInstalled, let error = reinstallIntegration(removeLegacy: false) {
            lastError = error
        }
        if previous.openAtLogin != settings.openAtLogin {
            setOpenAtLogin(settings.openAtLogin)
        }
    }

    /// Login item via SMAppService. Never registered in test mode: that would
    /// add the debug build to the real login items.
    func setOpenAtLogin(_ enabled: Bool) {
        guard environment.mode == .real else {
            log.log(.info, "login item \(enabled ? "on" : "off") (test mode: not registered)")
            return
        }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            lastError = "Não consegui \(enabled ? "ativar" : "desativar") a abertura ao iniciar a sessão: \(error.localizedDescription)"
        }
    }

    /// Versions and paths for Ajustes > Avançado and "Copiar diagnóstico".
    func diagnostics() async -> String {
        var lines = ["MultiCred \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") (\(environment.mode.rawValue))"]
        for tool in Tool.allCases {
            lines.append("\(tool.rawValue): \(await tools.locate(tool)?.path ?? "não encontrado")")
        }
        lines.append("shells: \(config.settings.enabledShells.map(\.rawValue).joined(separator: ", "))")
        lines.append("--- log ---")
        lines += log.tail(50)
        return lines.joined(separator: "\n")
    }
}
