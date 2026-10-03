import Foundation
import XCTest
@testable import MultiCredCore

final class ConfigEditorTests: SafeTestCase {
    func testAPIKeyLifecycleKeepsValueOnlyInKeychain() throws {
        let (config, key) = try ConfigEditor.addAPIKey(
            nickname: "NPU", provider: .openai, envVar: "OPENAI_API_KEY", secret: "  sk-123  ",
            color: .indigo, to: Config(), keychain: keychain
        )
        XCTAssertEqual(keychain.storedValue(account: key.keychainAccount), Data("sk-123".utf8))
        let json = String(decoding: try JSONFileStore<Config>.encoder().encode(config), as: UTF8.self)
        XCTAssertFalse(json.contains("sk-123"), "the secret never reaches config.json")

        try ConfigEditor.replaceSecret(of: key, with: "sk-456", keychain: keychain)
        XCTAssertEqual(keychain.storedValue(account: key.keychainAccount), Data("sk-456".utf8))

        var withProfile = config
        withProfile.profiles.append(Profile(name: "P", color: .indigo, apiKeyIds: [key.id]))
        let removed = try ConfigEditor.removeAPIKey(key.id, from: withProfile, keychain: keychain)
        XCTAssertEqual(removed.apiKeys, [])
        XCTAssertEqual(removed.profiles[0].apiKeyIds, [])
        XCTAssertNil(keychain.storedValue(account: key.keychainAccount))
    }

    func testInvalidKeyIsNotStored() {
        XCTAssertThrowsError(try ConfigEditor.addAPIKey(
            nickname: "x", provider: .other, envVar: "bad name", secret: "v", color: .red, to: Config(), keychain: keychain
        ))
        XCTAssertEqual(try keychain.allAccounts(), [])
        XCTAssertThrowsError(try ConfigEditor.addAPIKey(
            nickname: "x", provider: .openai, envVar: "OPENAI_API_KEY", secret: "  ", color: .red, to: Config(), keychain: keychain
        )) { XCTAssertEqual($0 as? EditorError, .emptySecret) }
    }

    func testOneKeyPerProviderInAProfile() throws {
        let a = APIKeyAccount(nickname: "A", provider: .openai, color: .red)
        let b = APIKeyAccount(nickname: "B", provider: .openai, color: .red)
        let g = APIKeyAccount(nickname: "G", provider: .gemini, color: .red)
        let config = Config(apiKeys: [a, b, g])
        var profile = Profile(name: "P", color: .red, apiKeyIds: [a.id, g.id])
        profile = ConfigEditor.setAPIKey(b.id, for: .openai, in: profile, config: config)
        XCTAssertEqual(Set(profile.apiKeyIds), [b.id, g.id])
        profile = ConfigEditor.setAPIKey(nil, for: .gemini, in: profile, config: config)
        XCTAssertEqual(profile.apiKeyIds, [b.id])
    }

    func testRemovingAccountsClearsProfileReferences() throws {
        let git = GitIdentity(nickname: "g", name: "G", email: "g@x.com", color: .red)
        let gh = GitHubAccount(nickname: "h", username: "h", color: .red)
        var config = Config(gitIdentities: [git], githubAccounts: [gh], profiles: [Profile(name: "P", color: .red, gitIdentityId: git.id, githubAccountId: gh.id)])
        config = ConfigEditor.removeGitIdentity(git.id, from: config)
        config = ConfigEditor.removeGitHubAccount(gh.id, from: config)
        XCTAssertNil(config.profiles[0].gitIdentityId)
        XCTAssertNil(config.profiles[0].githubAccountId)
        XCTAssertEqual(Validation.issues(in: config), [])
    }

    func testAddMissingGitHubAccountsIsCaseInsensitive() {
        let config = Config(githubAccounts: [GitHubAccount(nickname: "a", username: "Rafael-Leivas", color: .red)])
        let logins = [
            GitHubLogin(host: "github.com", login: "rafael-leivas", active: true, state: "success"),
            GitHubLogin(host: "github.com", login: "NPU-Rafael", active: false, state: "success"),
        ]
        let updated = ConfigEditor.addMissingGitHubAccounts(logins, to: config)
        XCTAssertEqual(updated.githubAccounts.map(\.username), ["Rafael-Leivas", "NPU-Rafael"])
    }
}

final class GitHubLoginTests: XCTestCase {
    func testRealOutputShape() {
        var parser = GitHubLoginParser()
        var machine = GitHubLoginStateMachine()
        let chunks = [
            "\u{1B}[0;33m!\u{1B}[0m First copy your one-time code: \u{1B}[1mAB12-CD34\u{1B}[0m\n",
            "Press Enter to open https://github.com/login/device in your browser... ",
        ]
        for chunk in chunks { parser.consume(Array(chunk.utf8)).forEach { machine.handle($0) } }
        XCTAssertEqual(machine.phase, .showingCode("AB12-CD34"))
        machine.browserOpened()
        XCTAssertEqual(machine.phase, .waitingForBrowser("AB12-CD34"))
        parser.consume(Array("\n\u{2713} Authentication complete.\n- gh config set -h github.com git_protocol https\n\u{2713} Logged in as octocat\n".utf8)).forEach { machine.handle($0) }
        XCTAssertEqual(machine.phase, .connected("octocat"))
        XCTAssertEqual(parser.loggedInAs, "octocat")
    }

    func testQuestionAndFailure() {
        var parser = GitHubLoginParser()
        let events = parser.consume(Array("? Authenticate Git with your GitHub credentials? (Y/n) \nerror: authorization expired\n".utf8))
        XCTAssertEqual(events.first, .question("? Authenticate Git with your GitHub credentials? (Y/n)"))
        XCTAssertEqual(events.last, .failed("error: authorization expired"))
    }

    func testSimulatorThroughRealPTY() {
        let pty = PseudoTerminalProcess()
        let done = expectation(description: "exit")
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var parser = GitHubLoginParser()
            var machine = GitHubLoginStateMachine()
        }
        let box = Box()
        XCTAssertNoThrow(try pty.start(
            executable: URL(fileURLWithPath: GitHubLoginSimulator.executable),
            arguments: GitHubLoginSimulator.arguments,
            environment: ["PATH": "/usr/bin:/bin"],
            onOutput: { data in box.lock.withLock { box.parser.consume(data).forEach { box.machine.handle($0) } } },
            onExit: { status in box.lock.withLock { box.machine.processExited(status: status, login: box.parser.loggedInAs) }; done.fulfill() }
        ))
        let deadline = Date().addingTimeInterval(5)
        while box.lock.withLock({ box.machine.code }) == nil, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertEqual(box.lock.withLock { box.machine.code }, "TEST-1234")
        pty.write(Data("\r".utf8))
        wait(for: [done], timeout: 10)
        XCTAssertEqual(box.lock.withLock { box.machine.phase }, .connected(GitHubLoginSimulator.simulatedLogin))
    }
}

final class SetupDetectorTests: SafeTestCase {
    func testDetectsToolsGitGitHubAndClaudeFolders() async throws {
        for name in [".claude", ".claude-pessoal"] {
            try FileManager.default.createDirectory(at: home.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        try Data(#"{"oauthAccount":{"emailAddress":"p@x.com"}}"#.utf8).write(to: home.appendingPathComponent(".claude-pessoal/.claude.json"))
        try Data("{}".utf8).write(to: home.appendingPathComponent(".claude.json"))
        runner.on("git", ["--version"], stdout: "git version 2.54.0\n")
        runner.on("gh", ["--version"], stdout: "gh version 2.101.0\n")
        runner.on("claude", ["--version"], stdout: "2.1.288 (Claude Code)\n")
        runner.on("git", ["config", "--global", "--includes", "--get", "user.name"], stdout: "Rafael\n")
        runner.on("git", ["config", "--global", "--includes", "--get", "user.email"], stdout: "r@work.example\n")
        runner.on("gh", ["auth", "status"], stdout: #"{"hosts":{"github.com":[{"host":"github.com","login":"rafael-npu","active":true,"state":"success"},{"host":"github.com","login":"rafaelb","active":false,"state":"success"}]}}"#)

        let setup = await SetupDetector(environment: environment, tools: FakeTools()).detect()
        XCTAssertEqual(setup.tools.map(\.version), ["git version 2.54.0", "gh version 2.101.0", "2.1.288 (Claude Code)"])
        XCTAssertEqual(setup.gitEmail, "r@work.example")
        XCTAssertEqual(setup.githubLogins.count, 2)
        XCTAssertEqual(setup.claudeFolders.map(\.configDir), [nil, home.path + "/.claude-pessoal"])
        XCTAssertEqual(setup.claudeFolders[1].status, .loggedIn(email: "p@x.com"))
        XCTAssertFalse(setup.hasLegacyInstall)

        let (config, initial) = SetupDetector.suggestedConfig(from: setup, environment: environment)
        XCTAssertEqual(Validation.issues(in: config), [])
        XCTAssertEqual(config.profiles.map(\.name), ["Principal"])
        XCTAssertEqual(initial, config.profiles[0].id)
        XCTAssertEqual(config.githubAccount(config.profiles[0].githubAccountId)?.username, "rafael-npu")
        XCTAssertEqual(config.githubAccounts.count, 2)
        XCTAssertEqual(config.claudeAccounts.map(\.configDir), [nil, home.path + "/.claude-pessoal"])
        XCTAssertEqual(config.claudeAccounts[1].email, "p@x.com")
    }

    func testLegacyProfilesWinAndActiveProfileIsKept() {
        var setup = DetectedSetup()
        setup.legacyProfiles = [
            .init(key: "TRABALHO", gitName: "NPU", gitEmail: "r@work.example", githubUser: "NPU-Rafael", sshKey: nil, claudeDir: nil),
            .init(key: "PESSOAL", gitName: "Rafael", gitEmail: "r@gmail.com", githubUser: "Rafael-L", sshKey: nil, claudeDir: home.path + "/.claude-pessoal"),
        ]
        setup.legacyActiveKey = "PESSOAL"
        setup.githubLogins = [GitHubLogin(host: "github.com", login: "rafael-l", active: true, state: "success")]
        let (config, initial) = SetupDetector.suggestedConfig(from: setup, environment: environment)
        XCTAssertEqual(config.profiles.map(\.name), ["Trabalho", "Pessoal"])
        XCTAssertEqual(initial, config.profiles[1].id)
        XCTAssertEqual(config.githubAccount(config.profiles[1].githubAccountId)?.username, "rafael-l", "gh's spelling")
        XCTAssertNil(config.claudeAccount(config.profiles[0].claudeAccountId)?.configDir)
        XCTAssertEqual(config.claudeAccount(config.profiles[1].claudeAccountId)?.configDir, home.path + "/.claude-pessoal")
        XCTAssertEqual(Validation.issues(in: config), [])
    }
}

final class VerifierTests: SafeTestCase {
    private var config: Config!
    private var profile: Profile!
    private var paths: AppPaths { AppPaths(environment: environment) }

    override func setUpWithError() throws {
        try super.setUpWithError()
        let git = GitIdentity(nickname: "N", name: "Rafael", email: "r@work.example", color: .indigo)
        let gh = GitHubAccount(nickname: "N", username: "rafael-npu", color: .indigo)
        let claude = ClaudeAccount(nickname: "N", color: .indigo, configDir: nil)
        let key = APIKeyAccount(nickname: "N", provider: .openai, color: .indigo)
        try keychain.setSecret(Data("sk".utf8), account: key.keychainAccount)
        profile = Profile(name: "Trabalho", color: .indigo, gitIdentityId: git.id, githubAccountId: gh.id, claudeAccountId: claude.id, apiKeyIds: [key.id])
        config = Config(gitIdentities: [git], githubAccounts: [gh], claudeAccounts: [claude], apiKeys: [key], profiles: [profile])
    }

    private func healthySystem() async throws -> ActiveState {
        try Installer(environment: environment).apply(InstallOptions(shells: [.zsh], removeLegacy: false))
        runner.on("gh", ["config", "get"], stdout: "rafael-npu\n")
        runner.on("gh", ["auth", "switch"])
        runner.on("launchctl", ["getenv"], stdout: "")
        runner.on("launchctl", ["unsetenv"])
        let state = try await SwitchEngine(environment: environment, tools: FakeTools()).switchProfile(profile.id, in: config).state
        return state
    }

    private func verify(_ state: ActiveState, status: ClaudeLoginStatus = .loggedIn(email: "r@work.example"), sessions: Int = 0) async -> VerificationReport {
        await Verifier(environment: environment, tools: FakeTools(), processes: FixedProcessScanner(sessions: sessions))
            .run(config: config, state: state, checkGitHubTokens: false) { _ in status }
    }

    func testHealthySystemIsConsistent() async throws {
        let state = try await healthySystem()
        runner.on("git", ["config", "--includes", "--show-origin", "--get", "user.name"], stdout: "file:\(paths.gitconfig.path)\tRafael\n")
        runner.on("git", ["config", "--includes", "--show-origin", "--get", "user.email"], stdout: "file:\(paths.gitconfig.path)\tr@work.example\n")

        let report = await verify(state)
        XCTAssertTrue(report.isConsistent, report.problems.map(\.title).joined(separator: ", "))
        XCTAssertEqual(report.okCount, report.checks.count)
        XCTAssertEqual(Set(report.items.map(\.id)), ["git.user.name", "git.user.email", "gh.active", "claude.launchd", "claude.login", "key.\(config.apiKeys[0].id)", "shell.zsh", "git.include", "env.files"])
    }

    func testEmailOverriddenAfterIncludePointsAtTheFileAndReinstalls() async throws {
        let state = try await healthySystem()
        runner.on("git", ["config", "--includes", "--show-origin", "--get", "user.name"], stdout: "file:\(paths.gitconfig.path)\tRafael\n")
        runner.on("git", ["config", "--includes", "--show-origin", "--get", "user.email"], stdout: "file:\(home.path)/.gitconfig\tr@gmail.com\n")
        let item = await verify(state).items.first { $0.id == "git.user.email" }
        XCTAssertEqual(item?.status, .error)
        XCTAssertEqual(item?.detail, "r@gmail.com")
        XCTAssertEqual(item?.expected, "r@work.example")
        XCTAssertEqual(item?.origin, "~/.gitconfig")
        XCTAssertEqual(item?.fix, .reinstallIntegration)
    }

    func testDriftInGitHubLaunchdShellKeysAndLegacy() async throws {
        let state = try await healthySystem()
        runner.on("git", ["config"], stdout: "file:\(paths.gitconfig.path)\tRafael\n")
        // Later rules do not override earlier ones in the fake, so use a fresh runner state:
        let report1 = await verify(state)
        XCTAssertNil(report1.items.first { $0.id == "gh.active" && $0.status == .error })

        // Remove the zsh block, add the legacy line, drop the key, and log Claude out.
        try Data("[ -f \"$HOME/Perfis/claude-env.sh\" ] && source \"$HOME/Perfis/claude-env.sh\"\n".utf8)
            .write(to: home.appendingPathComponent(".zshrc"))
        try keychain.deleteItem(account: config.apiKeys[0].keychainAccount)
        let report = await verify(state, status: .loggedOut, sessions: 2)

        func item(_ id: String) -> CheckItem? { report.items.first { $0.id == id } }
        XCTAssertEqual(item("shell.zsh")?.fix, .reinstallIntegration)
        XCTAssertEqual(item("legacy")?.fix, .removeLegacy)
        XCTAssertEqual(item("key.\(config.apiKeys[0].id)")?.fix, .setAPIKeySecret(config.apiKeys[0].id))
        XCTAssertEqual(item("claude.login")?.fix, .loginClaude(config.claudeAccounts[0].id))
        XCTAssertEqual(item("claude.sessions")?.status, .info)
        XCTAssertFalse(report.isConsistent)
    }

    func testFixPreviewsNameTheCommand() {
        XCTAssertEqual(Fix.switchGitHub(host: "github.com", user: "rafael-npu").commandPreview(config: config, environment: environment, profileName: "Trabalho"),
                       "gh auth switch --hostname github.com --user rafael-npu")
        XCTAssertTrue(Fix.reapplyProfile.commandPreview(config: config, environment: environment, profileName: "Trabalho").contains("Trabalho"))
    }
}

final class ProcessScannerTests: XCTestCase {
    /// Process tree observed on a real Mac with the native Claude Code install:
    /// three sessions (two launched from ~/.local/bin, one from the app) with
    /// version binaries and ClaudeCode.app helpers below them.
    func testCountsOnlySessionRootsInARealTree() {
        let home = "/Users/u"
        let tree: [(Int32, Int32, String)] = [
            (28412, 1, "\(home)/.local/bin/claude"),
            (28563, 28412, "\(home)/.local/share/claude/versions/2.1.288"),
            (28566, 28412, "\(home)/.local/share/claude/ClaudeCode.app/Contents/MacOS/claude"),
            (28597, 28563, "\(home)/.local/share/claude/versions/2.1.288"),
            (42763, 1, "\(home)/.local/bin/claude"),
            (80858, 1, "\(home)/.local/share/claude/ClaudeCode.app/Contents/MacOS/claude"),
            (80881, 80858, "\(home)/.local/share/claude/versions/2.1.285"),
            (90000, 1, "/bin/zsh"),
            (90001, 90000, "/opt/homebrew/bin/node"),
        ]
        let entries = tree.map { ProcessEntry(pid: $0.0, parent: $0.1, path: $0.2) }
        XCTAssertEqual(SystemProcessScanner.countSessions(in: entries), 3)
    }

    func testSessionStartedFromAShellCounts() {
        let entries = [
            ProcessEntry(pid: 10, parent: 1, path: "/bin/zsh"),
            ProcessEntry(pid: 11, parent: 10, path: "/Users/u/.local/share/claude/versions/2.1.288"),
        ]
        XCTAssertEqual(SystemProcessScanner.countSessions(in: entries), 1)
        XCTAssertEqual(SystemProcessScanner.countSessions(in: []), 0)
    }

    func testRealScanDoesNotCrash() {
        XCTAssertGreaterThanOrEqual(SystemProcessScanner().claudeCodeSessionCount(), 0)
    }
}
