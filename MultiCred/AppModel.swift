import Foundation
import MultiCredCore
import Observation

/// App-wide state on the main actor. Owns the configuration, the switch
/// engine and Claude status cache; views read it and call its methods.
@MainActor
@Observable
final class AppModel {
    let environment: SystemEnvironment
    let tools: ToolLocator
    let log: EventLog
    @ObservationIgnored private let repository: ConfigRepository
    @ObservationIgnored private let engine: SwitchEngine
    @ObservationIgnored private let statusService: ClaudeStatusService

    private(set) var config = Config()
    private(set) var state = ActiveState()
    private(set) var claudeStatuses: [UUID: ClaudeLoginStatus] = [:]
    private(set) var isSwitching = false
    /// Last user-facing problem, shown by the window that triggered it.
    var lastError: String?

    init(environment: SystemEnvironment) {
        self.environment = environment
        tools = ToolLocator(environment: environment)
        log = EventLog(directory: environment.logsDirectory)
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
    }

    // MARK: Claude accounts

    func claudeStatus(_ account: ClaudeAccount) -> ClaudeLoginStatus? {
        claudeStatuses[account.id]
    }

    func refreshClaudeStatuses(force: Bool = false) async {
        for account in config.claudeAccounts {
            let status = await statusService.status(for: account, force: force)
            claudeStatuses[account.id] = status
            if case let .loggedIn(email?) = status, account.email != email {
                updateClaudeAccount(account.id) { $0.email = email }
            }
        }
    }

    func refreshClaudeStatus(_ accountId: UUID) async {
        guard let account = config.claudeAccount(accountId) else { return }
        await statusService.invalidate(accountId)
        claudeStatuses[accountId] = await statusService.status(for: account, force: true)
        if case let .loggedIn(email?) = claudeStatuses[accountId], account.email != email {
            updateClaudeAccount(accountId) { $0.email = email }
        }
    }

    @discardableResult
    func addClaudeAccount(nickname: String, color: ProfileColor, folder: ClaudeFolderChoice) -> ClaudeAccount? {
        do {
            let (updated, account) = try ClaudeAccountEditor.add(
                nickname: nickname, color: color, folder: folder, to: config, environment: environment
            )
            try save(updated)
            log.log(.info, "claude account added: \(account.nickname) dir=\(account.configDir.map(environment.abbreviate) ?? "default")")
            return account
        } catch {
            lastError = UserMessages.describe(error)
            return nil
        }
    }

    func removeClaudeAccount(_ accountId: UUID) {
        do {
            try save(ClaudeAccountEditor.remove(accountId, from: config))
            claudeStatuses[accountId] = nil
        } catch {
            lastError = UserMessages.describe(error)
        }
    }

    func profilesUsing(_ accountId: UUID) -> [Profile] {
        ClaudeAccountEditor.profilesUsing(accountId, in: config)
    }

    /// The Claude account currently applied (profile's or override).
    var appliedClaudeAccount: ClaudeAccount? {
        config.claudeAccount(state.appliedClaudeAccountId)
    }

    var activeProfile: Profile? {
        config.profile(state.profileId)
    }

    // MARK: Switching

    /// Switches only the Claude account. Returns a user-facing error or nil.
    @discardableResult
    func switchClaudeOnly(to accountId: UUID?) async -> String? {
        guard !isSwitching else { return UserMessages.busy }
        isSwitching = true
        defer { isSwitching = false }
        do {
            let result = try await engine.switchClaudeOnly(to: accountId, in: config)
            state = result.state
            return nil
        } catch {
            let message = UserMessages.describe(error)
            lastError = message
            return message
        }
    }

    // MARK: Persistence

    private func updateClaudeAccount(_ id: UUID, _ change: (inout ClaudeAccount) -> Void) {
        guard let index = config.claudeAccounts.firstIndex(where: { $0.id == id }) else { return }
        var updated = config
        change(&updated.claudeAccounts[index])
        try? save(updated)
    }

    private func save(_ updated: Config) throws {
        try repository.save(updated)
        config = updated
    }
}
