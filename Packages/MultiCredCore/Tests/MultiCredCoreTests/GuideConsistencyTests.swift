import Foundation
import XCTest
@testable import MultiCredCore
@testable import MultiCredHelp

/// Keeps the guide honest: every path, file, command and screen label it cites
/// must exist in the code, and everything the README says the app changes must
/// be in the guide. A failure here means: update the guide (and the MCP tools).
final class GuideConsistencyTests: SafeTestCase {
    private let guide = Guide.bundled
    private var guideText: String { guide.about + "\n" + (guide.tasks + guide.problems).map { "\($0.title)\n\($0.body)" }.joined(separator: "\n") }

    private var repoRoot: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url
    }

    private func source(_ relative: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relative), encoding: .utf8)
    }

    private func appSourcesText() throws -> String {
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: repoRoot.appendingPathComponent("MultiCred"), includingPropertiesForKeys: nil))
        var text = ""
        for case let file as URL in enumerator where file.pathExtension == "swift" {
            text += (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        }
        return text
    }

    func testGuideVersionMatchesTheAppVersion() throws {
        let pbxproj = try source("MultiCred.xcodeproj/project.pbxproj")
        let versions = Set(pbxproj.components(separatedBy: "\n").compactMap { line -> String? in
            guard let range = line.range(of: "MARKETING_VERSION = ") else { return nil }
            return line[range.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: "; "))
        })
        XCTAssertEqual(versions, [guide.version], "guia.md `versão:` must equal MARKETING_VERSION")
    }

    func testGuideFactsMatchCode() throws {
        let appPaths = AppPaths(environment: environment)
        let support = environment.abbreviate(appPaths.root.path) + "/"
        let logs = environment.abbreviate(environment.logsDirectory.path) + "/"
        let anchors: [String] = [
            ManagedBlock.begin,
            support, logs,
            appPaths.config.lastPathComponent, appPaths.state.lastPathComponent, appPaths.gitconfig.lastPathComponent,
            appPaths.envSh.lastPathComponent, appPaths.envFish.lastPathComponent,
            appPaths.shellDirectory.lastPathComponent, appPaths.backups.lastPathComponent,
            environment.abbreviate(Integrations.fishConfFile(environment: environment).path),
            environment.abbreviate(Integrations.globalGitConfig(environment: environment).path),
            KeychainConstants.apiKeyService,
            SwitchEngine.claudeVariable,
        ] + ShellKind.allCases.flatMap { Integrations.rcFiles(for: $0, environment: environment).map { environment.abbreviate($0.path) } }
        for anchor in anchors where !anchor.contains("gitconfig") || anchor == appPaths.gitconfig.lastPathComponent {
            XCTAssertTrue(guideText.contains(anchor), "guide lacks `\(anchor)`")
        }
        for command in ["launchctl setenv", "gh auth switch", "claude auth login", "claude auth status", "/usr/bin/security", "claude mcp add", "claude mcp remove multicred"] {
            XCTAssertTrue(guideText.contains(command), "guide lacks `\(command)`")
        }
        for tool in Tool.allCases { XCTAssertTrue(guideText.contains("`\(tool.rawValue)`") || guideText.contains(tool.displayName), "guide lacks \(tool)") }
    }

    func testEveryPathTheGuideCitesExistsInTheCode() throws {
        let known: Set<String> = Set(
            [environment.abbreviate(AppPaths(environment: environment).root.path) + "/", environment.abbreviate(environment.logsDirectory.path) + "/",
             environment.abbreviate(Integrations.fishConfFile(environment: environment).path)]
            + ShellKind.allCases.flatMap { Integrations.rcFiles(for: $0, environment: environment).map { environment.abbreviate($0.path) } }
            + ["~/.claude", "~/.claude-<nome>", "~/.claude*", "~/Perfis", "~/.config/fish/conf.d", "~/Library/Application Support/MultiCred/"]
        )
        let cited = guideText.components(separatedBy: "`").enumerated().filter { $0.offset % 2 == 1 }.map(\.element).filter { $0.hasPrefix("~") }
        XCTAssertFalse(cited.isEmpty)
        for path in cited { XCTAssertTrue(known.contains(path), "guide cites unknown path `\(path)`") }
    }

    func testEverythingTheREADMESaysTheAppChangesIsInTheGuide() throws {
        let readme = try source("README.md")
        let section = try XCTUnwrap(readme.components(separatedBy: "## O que o app altera").dropFirst().first?.components(separatedBy: "## ").first)
        let cited = section.components(separatedBy: "`").enumerated().filter { $0.offset % 2 == 1 }.map(\.element)
            .filter { $0.hasPrefix("~/") || $0.hasPrefix("#") || $0.hasPrefix("launchctl") || $0.hasPrefix("app.multicred") }
        XCTAssertGreaterThan(cited.count, 5)
        for item in cited {
            let probe = item.hasPrefix("launchctl") ? "launchctl setenv" : item
            XCTAssertTrue(guideText.contains(probe), "README says the app changes `\(item)` but the guide does not")
        }
    }

    func testScreenLabelsTheGuideCitesExistInTheApp() throws {
        let app = try appSourcesText()
        let labels = [
            "Criar um perfil…", "Trocar só a conta Claude", "Adicionar conta Claude…", "Verificar…", "Contas…", "Ajustes…",
            "Desinstalar…", "Copiar código e abrir o GitHub", "Corrigir tudo", "Copiar diagnóstico", "Ativar este perfil",
            "Adicionar chave", "Tentar de novo", "Configurar MultiCred…", "Ajuda com o Claude",
        ]
        for label in labels {
            XCTAssertTrue(app.contains(label), "app has no `\(label)`")
            XCTAssertTrue(guideText.contains(label) || label == "Configurar MultiCred…", "guide does not mention `\(label)`")
        }
        XCTAssertTrue(app.contains("curl -fsSL https://claude.ai/install.sh | bash"))
        XCTAssertTrue(guideText.contains("curl -fsSL https://claude.ai/install.sh | bash"))
    }

    func testHelpServerHasAFixedReadOnlyToolList() async throws {
        let diagnostics = DiagnosticService(environment: environment.readOnly(), tools: FakeTools(), processes: FixedProcessScanner(sessions: 0), guide: guide)
        let server = MCPServer.help(guide: guide, diagnostics: diagnostics)
        let line = await server.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)
        let reply = try XCTUnwrap(line)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])
        let tools = try XCTUnwrap((object["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.compactMap { $0["name"] as? String }, ["sobre_o_multicred", "como_fazer", "solucao_de_problemas", "diagnostico_do_meu_multicred"])
        for tool in tools { XCTAssertEqual((tool["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool, true) }
    }
}
