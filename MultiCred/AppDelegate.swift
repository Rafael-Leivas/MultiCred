import AppKit
import MultiCredCore
import SwiftUI

/// Status item and the menu (design 01a): header, profiles ⌘1…⌘9,
/// "Trocar só a conta Claude", Verificar ⌘R, Contas, Ajustes ⌘, and Sair ⌘Q.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private let model = AppModel(runtime: AppRuntime.make())
    private lazy var windows = WindowManager(model: model)
    private let feedback = SwitchFeedbackPresenter()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.setAccessibilityLabel("MultiCred")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
        updateIcon()

        model.onSwitched = { [weak self] outcome in
            guard let self else { return }
            self.updateIcon()
            self.feedback.present(outcome, feedback: self.model.config.settings.switchFeedback)
        }
        model.log.log(.info, "launched in \(model.environment.mode.rawValue) mode")

        Task {
            await model.load()
            updateIcon()
            if model.isInstalled {
                await model.reapplyActiveProfile()
                await model.refreshClaudeStatuses()
            } else {
                windows.show()
            }
            updateIcon()
        }
        startObservingIcon()
    }

    /// Re-renders the icon whenever the active profile or consistency changes.
    private func startObservingIcon() {
        withObservationTracking {
            _ = model.activeProfile
            _ = model.consistency
            _ = model.config.profiles
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.updateIcon()
                self?.startObservingIcon()
            }
        }
    }

    private func updateIcon() {
        let alert: Bool = if case .problems = model.consistency { true } else { false }
        if let profile = model.activeProfile {
            statusItem?.button?.image = StatusIcon.image(for: profile, alert: alert)
            statusItem?.button?.toolTip = "MultiCred · \(profile.name)"
        } else {
            statusItem?.button?.image = StatusIcon.image(letter: "M", color: .systemGray, alert: alert)
            statusItem?.button?.toolTip = "MultiCred"
        }
    }

    // MARK: NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if model.isTestMode {
            menu.addItem(disabled("MODO DE TESTE · nada no seu Mac é alterado"))
            menu.addItem(.separator())
        }

        guard model.isInstalled else {
            menu.addItem(action("Configurar MultiCred…", #selector(openMain), key: "", symbol: "wand.and.stars"))
            menu.addItem(.separator())
            menu.addItem(quitItem())
            return
        }

        let header = NSMenuItem()
        let hosting = NSHostingView(rootView: MenuHeaderView(model: model) { [weak self, weak menu] in
            menu?.cancelTracking()
            self?.windows.show(.verify)
        })
        hosting.frame.size = hosting.fittingSize
        header.view = hosting
        menu.addItem(header)
        // Plain item as well: SwiftUI buttons inside menu views do not always get the click.
        if case .problems = model.consistency {
            let fix = action("Corrigir…", #selector(openVerify), key: "", symbol: "exclamationmark.triangle")
            menu.addItem(fix)
        }
        menu.addItem(.separator())

        menu.addItem(NSMenuItem.sectionHeader(title: "Perfis"))
        for (index, profile) in model.config.profiles.enumerated() {
            let item = NSMenuItem(title: profile.name, action: #selector(switchProfileFromMenu(_:)), keyEquivalent: index < 9 ? "\(index + 1)" : "")
            item.target = self
            item.representedObject = profile.id
            item.image = StatusIcon.image(for: profile, size: 18)
            item.state = profile.id == model.state.profileId ? .on : .off
            item.isEnabled = !model.isSwitching
            if model.needsClaudeLogin(profile) {
                if #available(macOS 14.4, *) {
                    item.subtitle = "⚠︎ Claude precisa entrar"
                } else {
                    item.title += "  ⚠︎ Claude precisa entrar"
                }
            }
            menu.addItem(item)
        }
        if model.config.profiles.isEmpty {
            menu.addItem(action("Criar um perfil…", #selector(newProfile), key: "", symbol: "plus"))
        }
        menu.addItem(.separator())

        let claudeItem = NSMenuItem(title: "Trocar só a conta Claude", action: nil, keyEquivalent: "")
        claudeItem.image = NSImage(systemSymbolName: "sparkle", accessibilityDescription: nil)
        claudeItem.submenu = claudeSubmenu()
        menu.addItem(claudeItem)
        menu.addItem(.separator())

        menu.addItem(action("Verificar…", #selector(openVerify), key: "r", symbol: "checkmark.shield"))
        menu.addItem(action("Contas…", #selector(openAccounts), key: "", symbol: "person"))
        menu.addItem(action("Ajustes…", #selector(openSettings), key: ",", symbol: "gearshape"))
        menu.addItem(.separator())
        menu.addItem(quitItem())

        Task {
            await model.refreshClaudeStatuses()
            if (model.verification?.checkedAt).map({ Date().timeIntervalSince($0) > 120 }) ?? true {
                await model.verify(checkTokens: false)
            }
        }
    }

    private func claudeSubmenu() -> NSMenu {
        let submenu = NSMenu()
        let profileName = model.activeProfile?.name
        let folder = model.activeProfile?.claudeConfigDir
        submenu.addItem(NSMenuItem.sectionHeader(title: profileName.map { "Conta Claude · pasta \(model.folderName(folder)) (\($0)) fica" } ?? "Conta Claude"))
        guard model.activeProfile != nil else {
            submenu.addItem(disabled("Ative um perfil primeiro"))
            return submenu
        }
        let profileAccountId = model.activeProfile?.claudeAccountId

        // The folder's own login.
        let folderLoggedOut = model.folderStatus(folder) == .loggedOut
        let own = NSMenuItem(
            title: "Login da pasta" + (folderLoggedOut ? " · Entrar…" : ""),
            action: folderLoggedOut ? #selector(folderLoginFromMenu) : #selector(switchClaudeFromMenu(_:)),
            keyEquivalent: ""
        )
        own.target = self
        own.state = model.state.appliedClaudeAccountId == nil ? .on : .off
        own.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        var ownSubtitle = "Sem login"
        if case let .loggedIn(email)? = model.folderStatus(folder) { ownSubtitle = email ?? "Logada" }
        if profileAccountId == nil { ownSubtitle += " · do perfil" }
        if #available(macOS 14.4, *) { own.subtitle = ownSubtitle } else { own.toolTip = ownSubtitle }
        own.isEnabled = !model.isSwitching
        submenu.addItem(own)

        for account in model.config.claudeAccounts {
            let hasToken = model.hasToken(account)
            let item = NSMenuItem(
                title: account.nickname + (hasToken ? "" : " · sem token"),
                action: #selector(switchClaudeFromMenu(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = account.id
            item.state = account.id == model.state.appliedClaudeAccountId ? .on : .off
            item.image = StatusIcon.image(letter: account.nickname, color: NSColor(hex: account.color.hex), size: 16)
            var subtitle = account.email ?? "conta Claude"
            if account.id == profileAccountId { subtitle += " · do perfil" }
            if #available(macOS 14.4, *) { item.subtitle = subtitle } else { item.toolTip = subtitle }
            item.isEnabled = !model.isSwitching && hasToken
            submenu.addItem(item)
        }
        submenu.addItem(.separator())
        submenu.addItem(action("Adicionar conta Claude…", #selector(addClaudeAccount), key: "", symbol: "plus"))
        submenu.addItem(.separator())
        submenu.addItem(disabled("Agents, skills e conversas não mudam."))
        submenu.addItem(disabled("Vale para novos terminais; sessões abertas continuam."))
        return submenu
    }

    // MARK: Actions

    @objc private func switchProfileFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID, let profile = model.config.profile(id) else { return }
        Task {
            if let error = await model.switchProfile(id) {
                showError("Não consegui trocar para \(profile.name)", error)
            } else if model.needsClaudeLogin(profile) {
                if let account = model.config.claudeAccount(profile.claudeAccountId) {
                    windows.show(.claude, then: .replaceClaudeToken(account.id))
                } else {
                    windows.showClaudeFolderLogin(profile.claudeConfigDir)
                }
            }
        }
    }

    @objc private func switchClaudeFromMenu(_ sender: NSMenuItem) {
        // No represented object = the folder's own login.
        let id = sender.representedObject as? UUID
        Task {
            if let error = await model.switchClaudeOnly(to: id) {
                showError("Não consegui trocar a conta Claude", error)
            }
        }
    }

    @objc private func folderLoginFromMenu() {
        windows.showClaudeFolderLogin(model.activeProfile?.claudeConfigDir)
    }

    @objc private func openMain() { windows.show() }
    @objc private func openVerify() { windows.show(.verify) }
    @objc private func openAccounts() { windows.show(.claude) }
    @objc private func openSettings() { windows.show(.settings) }
    @objc private func newProfile() { windows.show(.newProfile) }
    @objc private func addClaudeAccount() { windows.show(.claude, then: .addClaude) }

    private func showError(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Ok")
        alert.addButton(withTitle: "Abrir Verificar")
        NSApp.activate()
        if alert.runModal() == .alertSecondButtonReturn { windows.show(.verify) }
    }

    // MARK: Helpers

    private func quitItem() -> NSMenuItem {
        NSMenuItem(title: "Sair do MultiCred", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func action(_ title: String, _ selector: Selector, key: String, symbol: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        return item
    }
}
