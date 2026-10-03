import MultiCredCore
import Observation
import SwiftUI

/// Sections in the main window's sidebar (design 03, extended so profiles,
/// verify and settings live in the same window).
enum SidebarItem: Hashable {
    case profile(UUID)
    case newProfile
    case git
    case github
    case claude
    case apiKeys
    case verify
    case settings
}

/// Pages pushed inside a section. Sub-steps are pages, never new windows.
enum Route: Hashable {
    case editGit(UUID?)
    case editGitHub(UUID?)
    case githubLogin(String)
    case addClaude
    case claudeAccount(UUID)
    case claudeLogin(UUID)
    case editAPIKey(UUID?)
    case uninstall
}

/// Navigation for the single main window. Changing section clears the page
/// stack; leaving a login page stops its process.
@MainActor
@Observable
final class MainNavigator {
    var selection: SidebarItem? = .claude {
        didSet { if oldValue != selection { path = [] } }
    }
    var path: [Route] = [] {
        didSet { stopSessionsNoLongerShown() }
    }
    private(set) var claudeSessions: [UUID: LoginSession] = [:]
    private(set) var githubSessions: [String: GitHubLoginSession] = [:]
    @ObservationIgnored private let model: AppModel

    init(model: AppModel) {
        self.model = model
    }

    func show(_ item: SidebarItem, then route: Route? = nil) {
        selection = item
        path = route.map { [$0] } ?? []
    }

    func back() {
        if !path.isEmpty { path.removeLast() }
    }

    func push(_ route: Route) {
        path.append(route)
    }

    /// Opens the Claude login page, starting a fresh attempt.
    func showClaudeLogin(_ account: ClaudeAccount, replacingTop: Bool = false) {
        if selection != .claude { selection = .claude }
        claudeSessions.removeValue(forKey: account.id)?.stop()
        let session = LoginSession(account: account) { [weak self] phase in
            guard let self, phase == .connected else { return }
            Task { await self.model.refreshClaudeStatus(account.id) }
        }
        claudeSessions[account.id] = session
        replace(.claudeLogin(account.id), replacingTop: replacingTop)
        Task {
            switch await LoginCommand.make(for: account, model: model) {
            case let .success(command):
                model.log.log(.info, "claude login started for \(account.nickname) (\(model.claudeLoginMode))")
                session.start(command)
            case let .failure(error):
                session.failToLaunch(error.message)
            }
        }
    }

    /// Opens the GitHub login page (`gh auth login --web`, or the simulator in test mode).
    func showGitHubLogin(host: String = "github.com", replacingTop: Bool = false) {
        if selection != .github { selection = .github }
        githubSessions.removeValue(forKey: host)?.stop()
        let session = GitHubLoginSession(host: host) { [weak self] phase in
            guard let self, case let .connected(login) = phase else { return }
            Task { await self.model.didLogInToGitHub(login) }
        }
        githubSessions[host] = session
        replace(.githubLogin(host), replacingTop: replacingTop)
        Task {
            switch await GitHubLoginCommand.make(host: host, model: model) {
            case let .success(command): session.start(command)
            case let .failure(message): session.failToLaunch(message.text)
            }
        }
    }

    private func replace(_ route: Route, replacingTop: Bool) {
        var newPath = path
        if replacingTop, !newPath.isEmpty { newPath.removeLast() }
        newPath.removeAll { $0 == route }
        newPath.append(route)
        path = newPath
    }

    private func stopSessionsNoLongerShown() {
        let shown = Set(path)
        for id in claudeSessions.keys where !shown.contains(.claudeLogin(id)) {
            claudeSessions.removeValue(forKey: id)?.stop()
        }
        for host in githubSessions.keys where !shown.contains(.githubLogin(host)) {
            githubSessions.removeValue(forKey: host)?.stop()
        }
    }
}
