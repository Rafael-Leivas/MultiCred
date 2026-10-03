import MultiCredCore
import Observation
import SwiftUI

/// Pages inside the Accounts window. Everything is one window that navigates
/// forward and back; sub-steps never open extra windows or sheets.
enum AccountsRoute: Hashable {
    case addClaude
    case claudeLogin(UUID)
}

/// Navigation state of the Accounts window, plus the login sessions its pages
/// show. Leaving a login page (back, cancel, done) stops that login process.
@MainActor
@Observable
final class AccountsNavigator {
    var path: [AccountsRoute] = [] {
        didSet { stopSessionsNoLongerShown() }
    }
    private(set) var sessions: [UUID: LoginSession] = [:]
    @ObservationIgnored private let model: AppModel

    init(model: AppModel) {
        self.model = model
    }

    /// Opens the login page for `account`, starting a fresh attempt.
    /// `replacingTop` swaps the current page (used after "Adicionar" and "Tentar de novo").
    func showLogin(_ account: ClaudeAccount, replacingTop: Bool = false) {
        sessions.removeValue(forKey: account.id)?.stop()
        let session = LoginSession(account: account) { [weak self] phase in
            guard let self, phase == .connected else { return }
            Task { await self.model.refreshClaudeStatus(account.id) }
        }
        sessions[account.id] = session

        var newPath = path
        if replacingTop, !newPath.isEmpty { newPath.removeLast() }
        newPath.removeAll { $0 == .claudeLogin(account.id) }
        newPath.append(.claudeLogin(account.id))
        path = newPath

        Task {
            switch await LoginCommand.make(for: account, model: model) {
            case let .success(command):
                model.log.log(.info, "login started for \(account.nickname) (\(model.environment.mode.rawValue))")
                session.start(command)
            case let .failure(error):
                session.failToLaunch(error.message)
            }
        }
    }

    func showAddClaude() {
        path = [.addClaude]
    }

    func back() {
        if !path.isEmpty { path.removeLast() }
    }

    func reset() {
        path = []
    }

    private func stopSessionsNoLongerShown() {
        let shown = Set(path.compactMap { route -> UUID? in
            if case let .claudeLogin(id) = route { return id }
            return nil
        })
        for id in sessions.keys where !shown.contains(id) {
            sessions.removeValue(forKey: id)?.stop()
        }
    }
}
