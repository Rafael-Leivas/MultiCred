import AppKit
import MultiCredCore
import SwiftUI

/// Owns the single main window. A menu bar app has no main window by default,
/// so it is an NSWindow hosting SwiftUI; menu items open it on the right page.
@MainActor
final class WindowManager: NSObject, NSWindowDelegate {
    private let model: AppModel
    let navigator: MainNavigator
    private var window: NSWindow?

    init(model: AppModel) {
        self.model = model
        navigator = MainNavigator(model: model)
    }

    func show(_ item: SidebarItem? = nil, then route: Route? = nil) {
        if let item { navigator.show(item, then: route) }
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: MainWindowView(model: model, navigator: navigator)))
            window.title = "MultiCred"
            window.styleMask.insert([.closable, .miniaturizable, .resizable])
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.setContentSize(NSSize(width: 980, height: 660))
            window.center()
            window.setFrameAutosaveName("MultiCredMainWindow")
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func showClaudeLogin(_ account: ClaudeAccount) {
        show()
        navigator.showClaudeLogin(account)
    }

    func showGitHubLogin(host: String) {
        show()
        navigator.showGitHubLogin(host: host)
    }

    func windowWillClose(_ notification: Notification) {
        // Closing the window ends any login in progress.
        navigator.path = []
    }
}
