import AppKit
import MultiCredCore

/// Phase 1 shell: a status item that shows the runtime mode and where each tool
/// was found. The real menu (design 01a) arrives in Phase 4.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let environment = AppRuntime.makeEnvironment()
    private lazy var locator = ToolLocator(environment: environment)
    private lazy var log = EventLog(directory: environment.logsDirectory)

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = StatusIcon.image(letter: "M", color: .systemGray)
        item.button?.setAccessibilityLabel("MultiCred")
        statusItem = item
        log.log(.info, "launched in \(environment.mode.rawValue) mode, home=\(environment.abbreviate(environment.home.path))")
        rebuildMenu(tools: [:])
        Task { await refreshTools() }
    }

    private func refreshTools() async {
        var found: [Tool: String] = [:]
        for tool in Tool.allCases {
            found[tool] = await locator.locate(tool)?.path ?? "não encontrado"
        }
        rebuildMenu(tools: found)
    }

    private func rebuildMenu(tools: [Tool: String]) {
        let menu = NSMenu()
        menu.addItem(disabled(modeTitle))
        menu.addItem(disabled("HOME: \(environment.home.path)"))
        menu.addItem(.separator())
        menu.addItem(disabled("Ferramentas"))
        for tool in Tool.allCases {
            menu.addItem(disabled("  \(tool.displayName): \(tools[tool] ?? "procurando…")"))
        }
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Sair do MultiCred", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        statusItem?.menu = menu
    }

    private var modeTitle: String {
        switch environment.mode {
        case .real: "MultiCred · sistema real"
        case .dryRun: "MultiCred · MODO DE TESTE (nada é alterado)"
        case .test: "MultiCred · testes"
        }
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }
}
