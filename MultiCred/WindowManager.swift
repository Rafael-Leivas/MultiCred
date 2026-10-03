import AppKit
import MultiCredCore
import SwiftUI

/// Opens and reuses the app's windows. A menu bar app has no main window, so
/// each window is an NSWindow hosting a SwiftUI view, kept alive here.
/// Sub-steps (add account, login) are pages inside a window, never new windows.
@MainActor
final class WindowManager: NSObject, NSWindowDelegate {
    private let model: AppModel
    private let accountsNavigator: AccountsNavigator
    private var windows: [String: NSWindow] = [:]

    init(model: AppModel) {
        self.model = model
        accountsNavigator = AccountsNavigator(model: model)
    }

    /// Accounts window on the list.
    func showClaudeAccounts() {
        showAccountsWindow()
    }

    /// Accounts window on the "add account" page.
    func showAddClaudeAccount() {
        showAccountsWindow()
        accountsNavigator.showAddClaude()
    }

    /// Accounts window on the login page for `account`.
    func showLogin(for account: ClaudeAccount) {
        showAccountsWindow()
        accountsNavigator.path = []
        accountsNavigator.showLogin(account)
    }

    private func showAccountsWindow() {
        show(id: "accounts", title: "Contas") {
            ClaudeAccountsView(model: self.model, navigator: self.accountsNavigator)
        }
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

    private func bringToFront(_ window: NSWindow) {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, let id = window.identifier?.rawValue else { return }
        windows[id] = nil
        if id == "accounts" {
            // Closing the window ends any login in progress.
            accountsNavigator.reset()
        }
    }
}
