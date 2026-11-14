import Foundation
import XCTest
@testable import MultiCredCore
@testable import MultiCredHelp

final class DiagnosticToolTests: SafeTestCase {
    private var config: Config!
    private var profile: Profile!
    private var paths: AppPaths { AppPaths(environment: environment) }
    private let apiSecret = "sk-super-secret-value"
    private let vaultSecret = "oauth-super-secret-token"

    override func setUpWithError() throws {
        try super.setUpWithError()
        let git = GitIdentity(nickname: "N", name: "Rafael", email: "r@work.example", color: .indigo)
        let gh = GitHubAccount(nickname: "N", username: "rafael-npu", color: .indigo)
        let key = APIKeyAccount(nickname: "N", provider: .openai, color: .indigo)
        try keychain.setSecret(Data(apiSecret.utf8), account: key.keychainAccount)
        try claudeStore.writeVault("other-login", data: Data(vaultSecret.utf8))
        profile = Profile(name: "Trabalho", color: .indigo, gitIdentityId: git.id, githubAccountId: gh.id, claudeConfigDir: nil, apiKeyIds: [key.id])
        config = Config(gitIdentities: [git], githubAccounts: [gh], apiKeys: [key], profiles: [profile])
    }

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: String
        init(_ value: String) { stored = value }
        var value: String { get { lock.withLock { stored } } set { lock.withLock { stored = newValue } } }
    }

    /// A configured, switched system. `ghActive` and `claudeJSON` shape what the CLIs answer.
    private func prepare(ghActive: String = "rafael-npu", claudeJSON: String = #"{"loggedIn":true,"email":"r@work.example"}"#) async throws {
        try ConfigRepository(environment: environment).save(config)
        try Installer(environment: environment).apply(InstallOptions(shells: [.zsh], removeLegacy: false))
        let active = Box("rafael-npu")  // the switch must see the right account; the scenario changes it after
        runner.on("gh", ["auth", "switch"])
        runner.on("gh", ["config", "get"]) { _ in CommandResult(exitCode: 0, standardOutput: Data("\(active.value)\n".utf8)) }
        runner.on("launchctl", ["getenv"], stdout: "")
        runner.on("launchctl", ["unsetenv"])
        _ = try await SwitchEngine(environment: environment, tools: FakeTools()).switchProfile(profile.id, in: config)
        active.value = ghActive
        runner.on("git", ["--version"], stdout: "git version 2.54.0\n")
        runner.on("gh", ["--version"], stdout: "gh version 2.101.0 (2026-09-01)\n")
        runner.on("claude", ["--version"], stdout: "2.1.288 (Claude Code)\n")
        runner.on("claude", ["auth", "status"], stdout: claudeJSON)
        runner.on("git", ["config", "--includes", "--show-origin", "--get", "user.name"], stdout: "file:\(paths.gitconfig.path)\tRafael\n")
        runner.on("git", ["config", "--includes", "--show-origin", "--get", "user.email"], stdout: "file:\(paths.gitconfig.path)\tr@work.example\n")
    }

    private func diagnose() async -> String {
        let service = DiagnosticService(environment: environment.readOnly(), tools: FakeTools(), processes: FixedProcessScanner(sessions: 0), guide: .bundled)
        return await service.report()
    }

    func testDiagnosticMatchesVerifierAndNeverPrintsSecrets() async throws {
        try await prepare()
        let text = await diagnose()
        XCTAssertTrue(text.contains("Trabalho"), "active profile")
        XCTAssertTrue(text.contains("git version 2.54.0"))
        XCTAssertTrue(text.contains("Nenhum problema encontrado"), text)
        XCTAssertFalse(text.contains(apiSecret))
        XCTAssertFalse(text.contains(vaultSecret))

        // Same result as the Verify screen for the same state.
        let state = try StateStore(paths: paths).load()
        let report = await Verifier(environment: environment, tools: FakeTools(), processes: FixedProcessScanner(sessions: 0))
            .run(config: config, state: state, checkGitHubTokens: false) { _ in .loggedIn(email: "r@work.example") }
        XCTAssertTrue(report.isConsistent)
        for item in report.checks { XCTAssertTrue(text.contains(item.title), "missing check: \(item.title)") }
    }

    func testThreeDistinctProblemsAreExplainedWithGuideAndAppButton() async throws {
        try await prepare(ghActive: "someone-else", claudeJSON: #"{"loggedIn":false}"#)
        let zshrc = environment.home.appendingPathComponent(".zshrc")
        try Data("export FOO=1\n".utf8).write(to: zshrc)  // MultiCred block removed

        let text = await diagnose()
        let errors = text.components(separatedBy: "\n").filter { $0.hasPrefix("- [ERRO]") }
        XCTAssertEqual(errors.count, 3, text)
        XCTAssertTrue(text.contains("terminal-nao-trocou"))
        XCTAssertTrue(text.contains("gh-conta-errada"))
        XCTAssertTrue(text.contains("login-claude-falhou"))
        XCTAssertTrue(text.contains("Verificar"), "points at the app button")
        XCTAssertFalse(text.contains(apiSecret))
        XCTAssertFalse(text.contains(vaultSecret))
    }

    func testNotConfiguredPointsAtOnboarding() async {
        let text = await diagnose()
        XCTAssertTrue(text.contains("ainda não configurado"))
        XCTAssertTrue(text.contains("Configurar MultiCred"))
        XCTAssertTrue(text.contains("modo de teste"), "says it is not looking at the real Mac")
    }

    func testUnreadableConfigDoesNotLeakTheRawError() async throws {
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        try Data(#"{"version": "TOP-SECRET-FRAGMENT""#.utf8).write(to: paths.config)
        let text = await diagnose()
        XCTAssertTrue(text.contains("Não consegui ler"))
        XCTAssertFalse(text.contains("TOP-SECRET-FRAGMENT"))
    }

    func testToolIsReadOnlyAndListedByName() async throws {
        let service = DiagnosticService(environment: environment.readOnly(), tools: FakeTools(), processes: FixedProcessScanner(sessions: 0), guide: .bundled)
        let tool = DiagnosticTool(service: service)
        XCTAssertEqual(tool.name, "diagnostico_do_meu_multicred")
        let text = try await tool.call(arguments: [:])
        XCTAssertTrue(text.contains("Diagnóstico do MultiCred"))
    }

    func testDiagnosticDoesNotMigrateOrRewriteAnOldConfig() async throws {
        let v1 = #"""
        {"version":1,"gitIdentities":[],"githubAccounts":[],"apiKeys":[],
         "claudeAccounts":[{"id":"11111111-1111-1111-1111-111111111111","nickname":"Pessoal","color":"orange","configDir":"\#(home.path)/.claude-pessoal"}],
         "profiles":[{"id":"33333333-3333-3333-3333-333333333333","name":"Pessoal","color":"orange","icon":{"letter":{"_0":"P"}},"claudeAccountId":"11111111-1111-1111-1111-111111111111","apiKeyIds":[]}],
         "settings":{"switchFeedback":"hud","enabledShells":["zsh"],"openAtLogin":true}}
        """#
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        try Data(v1.utf8).write(to: paths.config)

        let text = await diagnose()
        XCTAssertEqual(try Data(contentsOf: paths.config), Data(v1.utf8), "config.json untouched")
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.root.appendingPathComponent("config.json.v1").path), "no backup copy written")
        XCTAssertTrue(text.contains("Pessoal"), "the old config is still understood")
    }

    func testHintsPointAtTheRightGuideEntry() async throws {
        try await prepare()
        try keychain.deleteItem(account: config.apiKeys[0].keychainAccount)  // API key value gone -> setAPIKeySecret fix
        let text = await diagnose()
        XCTAssertTrue(text.contains("chaves-de-api"), text)
        XCTAssertFalse(text.contains("keychain-pediu-senha"), "a missing key is not the password prompt problem")
    }
}
