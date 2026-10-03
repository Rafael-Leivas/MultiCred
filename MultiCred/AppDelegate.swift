import AppKit
import MultiCredCore

/// Status item and menu. Phase 3 adds Claude accounts and the
/// "switch only the Claude account" submenu; the full design 01a menu
/// (header, profiles, status) arrives in Phase 4.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private let model = AppModel(environment: AppRuntime.makeEnvironment())
    private lazy var windows = WindowManager(model: model)
    private var toolPaths: [Tool: String] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.setAccessibilityLabel("MultiCred")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
        updateIcon()

        model.log.log(.info, "launched in \(model.environment.mode.rawValue) mode")
        Task {
            await model.load()
            updateIcon()
            for tool in Tool.allCases {
                toolPaths[tool] = await model.tools.locate(tool)?.path ?? "não encontrado"
            }
            await model.refreshClaudeStatuses()
        }
    }

    private func updateIcon() {
        let account = model.appliedClaudeAccount
        let letter = model.activeProfile?.name ?? account?.nickname ?? "M"
        let color = (model.activeProfile?.color ?? account?.color).map { NSColor($0.color) } ?? .systemGray
        statusItem?.button?.image = StatusIcon.image(letter: letter, color: color)
    }

    // MARK: NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(disabled(modeTitle))
        if model.isTestMode {
            menu.addItem(disabled("HOME de teste: \(model.environment.home.path)"))
        }
        menu.addItem(.separator())

        let claudeItem = NSMenuItem(title: "Trocar só a conta Claude", action: nil, keyEquivalent: "")
        claudeItem.image = NSImage(systemSymbolName: "sparkle", accessibilityDescription: nil)
        claudeItem.submenu = claudeSubmenu()
        menu.addItem(claudeItem)
        menu.addItem(action("Contas Claude…", #selector(openClaudeAccounts), symbol: "person"))
        menu.addItem(.separator())

        menu.addItem(disabled("Ferramentas"))
        for tool in Tool.allCases {
            menu.addItem(disabled("  \(tool.displayName): \(toolPaths[tool] ?? "procurando…")"))
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Sair do MultiCred", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        Task { await model.refreshClaudeStatuses() }
    }

    private func claudeSubmenu() -> NSMenu {
        let submenu = NSMenu()
        let profileName = model.activeProfile?.name
        submenu.addItem(disabled(profileName.map { "Conta Claude · o perfil continua \($0)" } ?? "Conta Claude"))

        let profileAccountId = model.activeProfile?.claudeAccountId
        for account in model.config.claudeAccounts {
            let status = model.claudeStatus(account)
            let item: NSMenuItem
            if status?.isLoggedIn == false, case .loggedOut? = status {
                item = NSMenuItem(title: "\(account.nickname) · Entrar…", action: #selector(loginFromMenu(_:)), keyEquivalent: "")
            } else {
                item = NSMenuItem(title: account.nickname, action: #selector(switchClaudeFromMenu(_:)), keyEquivalent: "")
            }
            item.target = self
            item.representedObject = account.id
            item.state = account.id == model.state.appliedClaudeAccountId ? .on : .off
            item.image = StatusIcon.image(letter: account.nickname, color: NSColor(account.color.color), size: 16)
            var subtitle = account.email ?? model.environment.abbreviate(ClaudePaths.effectiveDirectory(of: account, environment: model.environment))
            if account.id == profileAccountId { subtitle += " · do perfil" }
            item.toolTip = subtitle
            if #available(macOS 14.4, *) { item.subtitle = subtitle }
            item.isEnabled = !model.isSwitching
            submenu.addItem(item)
        }
        if model.config.claudeAccounts.isEmpty {
            submenu.addItem(disabled("Nenhuma conta cadastrada"))
        }
        submenu.addItem(.separator())
        submenu.addItem(action("Adicionar conta Claude…", #selector(openClaudeAccounts), symbol: "plus"))
        submenu.addItem(.separator())
        submenu.addItem(disabled("Vale para novas sessões do Claude Code."))
        submenu.addItem(disabled("Sessões já abertas continuam na conta anterior."))
        return submenu
    }

    // MARK: Actions

    @objc private func openClaudeAccounts() {
        windows.showClaudeAccounts()
    }

    @objc private func loginFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID, let account = model.config.claudeAccount(id) else { return }
        windows.showLogin(for: account)
    }

    @objc private func switchClaudeFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        Task {
            if let error = await model.switchClaudeOnly(to: id) {
                showError(error)
            }
            updateIcon()
        }
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Não consegui trocar a conta Claude"
        alert.informativeText = message
        alert.alertStyle = .warning
        NSApp.activate()
        alert.runModal()
    }

    // MARK: Helpers

    private var modeTitle: String {
        switch model.environment.mode {
        case .real: "MultiCred"
        case .dryRun: "MultiCred · MODO DE TESTE (nada é alterado)"
        case .test: "MultiCred · testes"
        }
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func action(_ title: String, _ selector: Selector, symbol: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        return item
    }
}
