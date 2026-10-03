import AppKit
import MultiCredCore
import SwiftUI

/// Opens and reuses the app's windows. A menu bar app has no main window, so
/// each window is an NSWindow hosting a SwiftUI view, kept alive here.
@MainActor
final class WindowManager: NSObject, NSWindowDelegate {
    private let model: AppModel
    private var windows: [String: NSWindow] = [:]
    private var loginSessions: [UUID: LoginSession] = [:]

    init(model: AppModel) {
        self.model = model
    }

    func showClaudeAccounts() {
        show(id: "claude-accounts", title: "Contas Claude") {
            ClaudeAccountsView(model: self.model) { [weak self] account in self?.showLogin(for: account) }
        }
    }

    /// One login window per account; reopening brings the existing one forward.
    func showLogin(for account: ClaudeAccount) {
        let id = "login-\(account.id)"
        if let window = windows[id] {
            bringToFront(window)
            return
        }
        startLogin(for: account, windowID: id)
    }

    private func startLogin(for account: ClaudeAccount, windowID: String) {
        let session = LoginSession(account: account) { [weak self] phase in
            guard let self, phase == .connected else { return }
            Task { await self.model.refreshClaudeStatus(account.id) }
        }
        loginSessions[account.id] = session
        show(id: windowID, title: "Entrar no Claude") {
            LoginWindowView(
                session: session,
                model: self.model,
                onRetry: { [weak self] in self?.restartLogin(for: account, windowID: windowID) },
                onClose: { [weak self] in self?.close(windowID) }
            )
        }
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

    private func restartLogin(for account: ClaudeAccount, windowID: String) {
        close(windowID)
        startLogin(for: account, windowID: windowID)
    }

    private func show<Content: View>(id: String, title: String, @ViewBuilder content: () -> Content) {
        if let window = windows[id] {
            bringToFront(window)
            return
        }
        let window = NSWindow(contentViewController: NSHostingController(rootView: content()))
        window.title = title
        window.styleMask.insert([.closable, .miniaturizable, .resizable])
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier(id)
        window.delegate = self
        window.center()
        windows[id] = window
        bringToFront(window)
    }

    private func close(_ id: String) {
        windows[id]?.close()
    }

    private func bringToFront(_ window: NSWindow) {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, let id = window.identifier?.rawValue else { return }
        windows[id] = nil
        if id.hasPrefix("login-"), let uuid = UUID(uuidString: String(id.dropFirst("login-".count))) {
            loginSessions.removeValue(forKey: uuid)?.stop()
        }
    }
}
