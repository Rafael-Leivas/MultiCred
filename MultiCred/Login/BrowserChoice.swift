import AppKit
import SwiftUI

/// Which browser opens Claude's authorization link. The CLI is started with
/// BROWSER=/usr/bin/true (it honors it), so it never opens one on its own; the
/// app opens the link here, or only copies it.
enum BrowserChoice {
    static let storageKey = "claudeLoginBrowser"
    /// Stored value meaning "do not open, only copy the link".
    static let copyOnly = "copy"
    /// Value for the CLI's BROWSER variable: a no-op opener.
    static let suppressCLIBrowser = "/usr/bin/true"

    struct Browser: Identifiable, Hashable {
        let url: URL
        var id: String { url.path }
        var name: String { FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "") }
        var icon: NSImage { NSWorkspace.shared.icon(forFile: url.path) }
    }

    static var installed: [Browser] {
        guard let probe = URL(string: "https://claude.ai") else { return [] }
        return NSWorkspace.shared.urlsForApplications(toOpen: probe)
            .map(Browser.init)
            .reduce(into: [Browser]()) { list, browser in
                if !list.contains(where: { $0.name == browser.name }) { list.append(browser) }
            }
    }

    static var defaultBrowser: Browser? {
        guard let probe = URL(string: "https://claude.ai"), let app = NSWorkspace.shared.urlForApplication(toOpen: probe) else { return nil }
        return Browser(url: app)
    }

    /// Opens `url` according to the stored choice ("" = default browser).
    /// Returns false when the choice is "only copy" (the link is copied).
    @discardableResult
    static func open(_ url: URL, choice: String) -> Bool {
        if choice == copyOnly {
            copy(url)
            return false
        }
        if !choice.isEmpty, FileManager.default.fileExists(atPath: choice) {
            NSWorkspace.shared.open([url], withApplicationAt: URL(fileURLWithPath: choice), configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
        return true
    }

    static func open(_ url: URL, in browser: Browser) {
        NSWorkspace.shared.open([url], withApplicationAt: browser.url, configuration: NSWorkspace.OpenConfiguration())
    }

    static func copy(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    static func label(for choice: String) -> String {
        if choice == copyOnly { return "Não abrir, só copiar o link" }
        if !choice.isEmpty, FileManager.default.fileExists(atPath: choice) { return Browser(url: URL(fileURLWithPath: choice)).name }
        return "Navegador padrão" + (defaultBrowser.map { " (\($0.name))" } ?? "")
    }
}

/// "Abrir em" picker shown before a login starts.
struct BrowserChoicePicker: View {
    @AppStorage(BrowserChoice.storageKey) private var choice = ""

    var body: some View {
        Picker("Abrir o link em", selection: $choice) {
            Text(BrowserChoice.label(for: "")).tag("")
            ForEach(BrowserChoice.installed) { browser in
                Text(browser.name).tag(browser.url.path)
            }
            Divider()
            Text(BrowserChoice.label(for: BrowserChoice.copyOnly)).tag(BrowserChoice.copyOnly)
        }
    }
}

/// "Copiar link" + "Abrir em ▾" for an authorization link already issued.
struct AuthorizationLinkActions: View {
    let url: URL?
    @State private var copied = false

    var body: some View {
        HStack(spacing: 8) {
            Button {
                guard let url else { return }
                BrowserChoice.copy(url)
                copied = true
                Task { try? await Task.sleep(for: .seconds(2)); copied = false }
            } label: {
                Label(copied ? "Link copiado" : "Copiar link", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            Menu {
                if let browser = BrowserChoice.defaultBrowser {
                    Button("Navegador padrão (\(browser.name))") { if let url { NSWorkspace.shared.open(url) } }
                    Divider()
                }
                ForEach(BrowserChoice.installed) { browser in
                    Button {
                        if let url { BrowserChoice.open(url, in: browser) }
                    } label: {
                        Label { Text(browser.name) } icon: { Image(nsImage: browser.icon) }
                    }
                }
            } label: {
                Label("Abrir em", systemImage: "safari")
            }
            .fixedSize()
        }
        .disabled(url == nil)
        .controlSize(.small)
    }
}
