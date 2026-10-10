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
    /// Token account in use; nil = the profile folder's own login.
    var appliedClaudeAccount: ClaudeAccount? { config.claudeAccount(state.appliedClaudeAccountId) }

    var consistency: Consistency {
        guard let verification else { return .unknown }
        guard let first = verification.problems.first else { return .ok }
        return .problems(count: verification.problems.count, first: first.title)
    }

    /// Login status of a Claude folder itself (nil path = ~/.claude).
    func folderStatus(_ configDir: String?) -> ClaudeLoginStatus? {
        claudeStatuses[ClaudeFolder.ownLogin(configDir).id]
    }

    func folderName(_ configDir: String?) -> String {
        configDir.map(environment.abbreviate) ?? "~/.claude"
    }

    /// What authenticates a profile right now, in words.
    func claudeCredentialDescription(for profile: Profile?) -> String {
        if let account = appliedClaudeAccount { return account.nickname }
        if case let .loggedIn(email?)? = folderStatus(profile?.claudeConfigDir) { return "login da pasta (\(email))" }
        return "login da pasta"
    }

    /// A profile cannot really be used while its Claude credential is missing.
    func needsClaudeLogin(_ profile: Profile) -> Bool {
        if let account = config.claudeAccount(profile.claudeAccountId) { return !hasToken(account) }
        return folderStatus(profile.claudeConfigDir) == .loggedOut
    }

    func hasToken(_ account: ClaudeAccount) -> Bool {
        (try? environment.keychain.containsItem(account: account.keychainAccount)) ?? false
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
    /// `accountId` nil = the profile folder's own login.
    func switchClaudeOnly(to accountId: UUID?) async -> String? {
        let override = ClaudeFolder.override(for: accountId, profile: activeProfile)
        return await performSwitch(claudeOnly: true) { try await self.engine.switchClaudeOnly(to: override, in: self.config) }
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
                runningClaudeSessions: processScanner.claudeCodeSessionCount(),
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
        do {
            let (updated, key) = try ConfigEditor.addAPIKey(
                nickname: nickname, provider: provider, envVar: envVar, secret: secret,
                color: color, to: config, keychain: environment.keychain
            )
            do {
                try repository.save(updated)
            } catch {
                // Never leave a secret in the Keychain that no configuration points to.
                try? environment.keychain.deleteItem(account: key.keychainAccount)
                throw error
            }
            config = updated
            return key
        } catch {
            lastError = UserMessages.describe(error)
            return nil
        }
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

    // MARK: Claude folders (own login) and token accounts

    /// Folders used by profiles, plus the default one.
    var claudeFoldersInUse: [String?] {
        var seen: [String?] = []
        for dir in [nil] + config.profiles.map(\.claudeConfigDir) where !seen.contains(dir) { seen.append(dir) }
        return seen
    }

    func refreshClaudeStatuses(force: Bool = false) async {
        for dir in claudeFoldersInUse {
            await refreshFolderStatus(dir, force: force)
        }
    }

    func refreshFolderStatus(_ configDir: String?, force: Bool = true) async {
        let pseudo = ClaudeFolder.ownLogin(configDir)
        if force { await statusService.invalidate(pseudo.id) }
        claudeStatuses[pseudo.id] = await statusService.status(for: pseudo)
    }

    /// Creates the folder if needed and returns its canonical path (nil = ~/.claude).
    func prepareClaudeFolder(_ choice: ClaudeFolderChoice) -> String?? {
        do {
            return .some(try ClaudeAccountEditor.prepareFolder(choice, environment: environment))
        } catch {
            lastError = UserMessages.describe(error)
            return nil
        }
    }

    @discardableResult
    func addClaudeTokenAccount(nickname: String, email: String?, color: ProfileColor, token: String) -> ClaudeAccount? {
        do {
            let (updated, account) = try ClaudeAccountEditor.addTokenAccount(
                nickname: nickname, email: email, color: color, token: token, to: config, keychain: environment.keychain
            )
            do {
                try repository.save(updated)
            } catch {
                try? environment.keychain.deleteItem(account: account.keychainAccount)
                throw error
            }
            config = updated
            log.log(.info, "claude token account added: \(account.nickname)")
            return account
        } catch {
            lastError = UserMessages.describe(error)
            return nil
        }
    }

    func replaceClaudeToken(of account: ClaudeAccount, with token: String) -> Bool {
        do {
            try ClaudeAccountEditor.replaceToken(of: account, with: token, keychain: environment.keychain)
            log.log(.info, "claude token replaced: \(account.nickname)")
            return true
        } catch {
            lastError = UserMessages.describe(error)
            return false
        }
    }

    func removeClaudeAccount(_ accountId: UUID) {
        let wasApplied = state.appliedClaudeAccountId == accountId
        guard edit({ ClaudeAccountEditor.remove(accountId, from: $0, keychain: environment.keychain) }) else { return }
        // Shells must stop exporting a token that no longer exists.
        if wasApplied { Task { await switchClaudeOnly(to: nil) } }
    }

    func profilesUsing(claudeAccount accountId: UUID) -> [Profile] {
        config.profiles.filter { $0.claudeAccountId == accountId }
    }

    /// `claude auth logout` for one folder (or clears the simulated state file).
    func logoutClaudeFolder(_ configDir: String?) async -> String? {
        let account = ClaudeFolder.ownLogin(configDir)
        defer { Task { await refreshFolderStatus(configDir) } }

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
                log.log(.info, "claude logout for folder \(folderName(configDir))")
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
        /// New token for a Claude account.
        case openClaudeToken(UUID)
        /// Log in a Claude folder itself.
        case openClaudeFolderLogin(String?)
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
        case let .loginClaude(id): result = .openClaudeToken(id)
        case let .loginClaudeFolder(dir): result = .openClaudeFolderLogin(dir)
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

    /// Claude folders and their logins are left alone; the Uninstaller deletes
    /// the Claude tokens with the other Keychain items.
    func uninstall() async -> UninstallReport {
        let report = await Uninstaller(environment: environment).apply()
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
        // A build run from Xcode's folder would leave a stale login item behind.
        let bundlePath = Bundle.main.bundlePath
        let inApplications = bundlePath.hasPrefix("/Applications/") || bundlePath.hasPrefix(environment.home.path + "/Applications/")
        if enabled, !inApplications {
            lastError = "“Abrir ao iniciar a sessão” só funciona com o MultiCred na pasta Aplicativos. Mova o app para lá e ative de novo em Ajustes."
            return
        }
        do {
            if enabled {
                try SMAppService.mainApp.register()
                if SMAppService.mainApp.status == .requiresApproval {
                    lastError = "O macOS pediu aprovação: ative o MultiCred em Ajustes do Sistema › Geral › Itens de Início."
                    SMAppService.openSystemSettingsLoginItems()
                }
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
