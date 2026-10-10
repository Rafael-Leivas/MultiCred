import Foundation
import XCTest
@testable import MultiCredCore

final class LoginOutputParserTests: XCTestCase {
    /// Shape of the real transcript from the Phase 1 spike: OSC 8 hyperlink,
    /// colors, prompt without newline, success on the same line.
    private let realTranscript =
        "Opening browser to sign in\u{2026}\r\n"
        + "If the browser didn't open, visit: \u{1B}]8;;https://claude.com/cai/oauth/authorize?code=true&client_id=abc&state=xyz\u{07}"
        + "\u{1B}[94mhttps://claude.com/cai/oauth/authorize?code=true&client_id=abc&state=xyz\u{1B}[39m\u{1B}]8;;\u{07}\r\n"
        + "Paste code here if prompted > "

    func testRealTranscriptProducesEventsInOrder() {
        var parser = LoginOutputParser()
        let events = parser.consume(Array(realTranscript.utf8))
        XCTAssertEqual(events, [
            .openingBrowser,
            .authorizationURL(URL(string: "https://claude.com/cai/oauth/authorize?code=true&client_id=abc&state=xyz")!),
            .promptingForCode,
        ])
        XCTAssertEqual(parser.consume(Array("Login successful.\r\n".utf8)), [.succeeded])
        XCTAssertFalse(parser.transcript.contains("\u{1B}"))
    }

    func testEventsSplitAcrossChunksFireOnce() {
        var parser = LoginOutputParser()
        var events: [LoginEvent] = []
        for byte in realTranscript.utf8 { events += parser.consume([byte]) }
        events += parser.consume(Array("Paste".utf8))
        XCTAssertEqual(events.filter { $0 == .promptingForCode }.count, 1)
        XCTAssertEqual(events.first, .openingBrowser)
    }

    func testFailureLine() {
        var parser = LoginOutputParser()
        let events = parser.consume(Array("Paste code here if prompted > \r\nError: Invalid code or expired\r\n".utf8))
        XCTAssertEqual(events, [.promptingForCode, .failed("Error: Invalid code or expired")])
    }

    /// Regression: the URL host "example.invalid" was read as a failure.
    func testFailureWordsInsideURLsAreIgnored() {
        var parser = LoginOutputParser()
        let events = parser.consume(Array("If the browser didn't open, visit: https://example.invalid/auth?error_uri=x&denied=0\r\n".utf8))
        XCTAssertEqual(events, [.authorizationURL(URL(string: "https://example.invalid/auth?error_uri=x&denied=0")!)])
    }

    func testStripEscapes() {
        XCTAssertEqual(LoginOutputParser.stripEscapes("\u{1B}[1;32mok\u{1B}[0m \u{1B}]0;title\u{1B}\\done\u{07}"), "ok done")
    }
}

final class LoginStateMachineTests: XCTestCase {
    func testFullManualCodeFlow() {
        var machine = LoginStateMachine()
        machine.handle(.openingBrowser)
        XCTAssertEqual(machine.phase, .waitingForBrowser)
        machine.handle(.authorizationURL(URL(string: "https://example.com/a")!))
        machine.handle(.promptingForCode)
        XCTAssertEqual(machine.phase, .waitingForCode)
        machine.codeSubmitted()
        XCTAssertEqual(machine.phase, .connecting)
        machine.handle(.succeeded)
        XCTAssertEqual(machine.phase, .connected)
        XCTAssertEqual(machine.authorizationURL?.absoluteString, "https://example.com/a")
    }

    func testBrowserCallbackCompletesWithoutCode() {
        var machine = LoginStateMachine()
        machine.handle(.openingBrowser)
        machine.handle(.promptingForCode)
        machine.handle(.succeeded)
        XCTAssertEqual(machine.phase, .connected)
    }

    func testFinalStatesAbsorbLaterEvents() {
        var machine = LoginStateMachine()
        machine.handle(.failed("Invalid code"))
        machine.handle(.succeeded)
        machine.processExited(status: 0)
        XCTAssertEqual(machine.phase, .failed("Invalid code"))

        var connected = LoginStateMachine()
        connected.handle(.succeeded)
        connected.processExited(status: 1)
        connected.timedOut()
        XCTAssertEqual(connected.phase, .connected)
    }

    func testExitTimeoutAndCancel() {
        var exited = LoginStateMachine()
        exited.processExited(status: 1)
        XCTAssertEqual(exited.phase, .failed("processo encerrado (código 1)"))

        var cleanExit = LoginStateMachine()
        cleanExit.handle(.promptingForCode)
        cleanExit.processExited(status: 0)
        XCTAssertEqual(cleanExit.phase, .connected)

        var timeout = LoginStateMachine()
        timeout.timedOut()
        XCTAssertEqual(timeout.phase, .failed("tempo esgotado"))

        var cancel = LoginStateMachine()
        cancel.cancelled()
        XCTAssertEqual(cancel.phase, .failed("cancelado"))
    }

    func testCodeIgnoredBeforeThePromptOrAfterTheEnd() {
        var machine = LoginStateMachine()
        machine.codeSubmitted()
        XCTAssertEqual(machine.phase, .starting)
    }
}

final class ClaudeStatusTests: SafeTestCase {
    private func account(_ dir: String?) -> ClaudeAccount {
        ClaudeAccount(nickname: "x", color: .teal, configDir: dir)
    }

    func testParseStatusVariants() {
        func parse(_ json: String) -> ClaudeLoginStatus? { ClaudeCLI.parseStatus(Data(json.utf8)) }
        XCTAssertEqual(parse(#"{"loggedIn": true, "email": "a@b.com"}"#), .loggedIn(email: "a@b.com"))
        XCTAssertEqual(parse(#"{"loggedIn": false}"#), .loggedOut)
        XCTAssertEqual(parse(#"{"authenticated": true, "account": {"emailAddress": "c@d.com"}}"#), .loggedIn(email: "c@d.com"))
        XCTAssertEqual(parse(#"{"oauthAccount": {"emailAddress": "e@f.com"}}"#), .loggedIn(email: "e@f.com"))
        XCTAssertNil(parse(#"{"something": "else"}"#))
        XCTAssertNil(parse("not json"))
    }

    func testStateFileLocationAndOAuthEntry() throws {
        let defaultAccount = account(nil)
        XCTAssertEqual(ClaudeAccountFiles.stateFile(for: defaultAccount, environment: environment).path, home.path + "/.claude.json")
        XCTAssertNil(ClaudeAccountFiles.statusFromStateFile(for: defaultAccount, environment: environment))

        try Data(#"{"userID": "u", "oauthAccount": {"emailAddress": "me@x.com", "accountUuid": "1"}}"#.utf8)
            .write(to: home.appendingPathComponent(".claude.json"))
        XCTAssertEqual(ClaudeAccountFiles.statusFromStateFile(for: defaultAccount, environment: environment), .loggedIn(email: "me@x.com"))

        let dir = home.appendingPathComponent(".claude-x")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"userID": "u"}"#.utf8).write(to: dir.appendingPathComponent(".claude.json"))
        XCTAssertEqual(ClaudeAccountFiles.statusFromStateFile(for: account(dir.path), environment: environment), .loggedOut)
    }

    func testServicePrefersCLIAndFillsEmailFromStateFile() async throws {
        try Data(#"{"oauthAccount": {"emailAddress": "file@x.com"}}"#.utf8).write(to: home.appendingPathComponent(".claude.json"))
        runner.on("claude", ["auth", "status", "--json"], stdout: #"{"loggedIn": true}"#)
        let service = ClaudeStatusService(environment: environment, tools: FakeTools())
        let status = await service.status(for: account(nil))
        XCTAssertEqual(status, .loggedIn(email: "file@x.com"))

        let request = try XCTUnwrap(runner.requests.first)
        XCTAssertNil(request.environment["CLAUDE_CONFIG_DIR"], "default account runs without the variable")
    }

    func testServiceSetsConfigDirAndFallsBackOnUnexpectedOutput() async throws {
        let dir = home.appendingPathComponent(".claude-y")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        runner.on("claude", ["auth", "status"], stdout: "Logged in (text, not json)")
        let service = ClaudeStatusService(environment: environment, tools: FakeTools())
        let status = await service.status(for: account(dir.path))
        XCTAssertEqual(status, .unknown("unexpected output (exit 0)"), "no state file: unknown, never 'logged out'")
        XCTAssertEqual(runner.requests.first?.environment["CLAUDE_CONFIG_DIR"], dir.path)
    }

    func testServiceCachesUntilForcedOrExpired() async throws {
        runner.on("claude", ["auth", "status"], stdout: #"{"loggedIn": false}"#)
        let service = ClaudeStatusService(environment: environment, tools: FakeTools())
        let acct = account(nil)
        _ = await service.status(for: acct)
        _ = await service.status(for: acct)
        XCTAssertEqual(runner.requests.count, 1)
        _ = await service.status(for: acct, force: true)
        XCTAssertEqual(runner.requests.count, 2)
    }

    func testWithoutClaudeInstalledUsesStateFileOnly() async throws {
        let service = ClaudeStatusService(environment: environment, tools: FakeTools(installed: [.git, .gh]))
        let status = await service.status(for: account(nil))
        XCTAssertEqual(status, .unknown("Claude Code not found"))
        XCTAssertTrue(runner.requests.isEmpty)
    }
}

final class ClaudeAccountEditorTests: SafeTestCase {
    private let token = "sk-ant-oat01-abcdefghijklmnopqrstuvwxyz0123456789"

    // MARK: Profile folders

    func testNewFolderIsCreatedPrivatelyAndCanonical() throws {
        let dir = try ClaudeAccountEditor.prepareFolder(.new("~/.claude-cliente-x/"), environment: environment)
        XCTAssertEqual(dir, home.path + "/.claude-cliente-x")
        XCTAssertEqual(try mode(of: home.appendingPathComponent(".claude-cliente-x")), 0o700)
    }

    func testDefaultFolderIsNilAndExplicitTildeClaudeToo() throws {
        XCTAssertNil(try ClaudeAccountEditor.prepareFolder(.defaultFolder, environment: environment))
        XCTAssertNil(try ClaudeAccountEditor.prepareFolder(.existing("~/.claude"), environment: environment))
    }

    func testExistingFolderMustExist() {
        XCTAssertThrowsError(try ClaudeAccountEditor.prepareFolder(.existing("~/.claude-missing"), environment: environment)) {
            XCTAssertEqual($0 as? ClaudeAccountError, .folderMissing(self.home.path + "/.claude-missing"))
        }
    }

    func testTestModeRefusesFoldersOutsideTheSandbox() {
        XCTAssertThrowsError(try ClaudeAccountEditor.prepareFolder(.new("/tmp/should-not-be-created-\(UUID().uuidString)"), environment: environment)) {
            guard case .outsideSandbox = $0 as? ClaudeAccountError else { return XCTFail("\($0)") }
        }
    }

    // MARK: Token accounts

    func testTokenAccountKeepsTheTokenOnlyInTheKeychain() throws {
        let (config, account) = try ClaudeAccountEditor.addTokenAccount(
            nickname: " Marco ", email: "marco@x.com", color: .teal, token: "  \(token)\n", to: Config(), keychain: keychain
        )
        XCTAssertEqual(account.nickname, "Marco")
        XCTAssertEqual(account.kind, .token)
        XCTAssertEqual(keychain.storedValue(account: account.keychainAccount), Data(token.utf8))
        let json = String(decoding: try JSONFileStore<Config>.encoder().encode(config), as: UTF8.self)
        XCTAssertFalse(json.contains(token), "the token never reaches config.json")
    }

    func testInvalidTokenIsRejectedAndNothingStored() {
        XCTAssertThrowsError(try ClaudeAccountEditor.addTokenAccount(nickname: "X", email: nil, color: .red, token: "not a token", to: Config(), keychain: keychain)) {
            XCTAssertEqual($0 as? ClaudeAccountError, .invalidToken)
        }
        XCTAssertEqual(try keychain.allAccounts(), [])
    }

    func testRemoveDeletesTokenAndFallsBackToFolderLogin() throws {
        var (config, account) = try ClaudeAccountEditor.addTokenAccount(nickname: "Marco", email: nil, color: .teal, token: token, to: Config(), keychain: keychain)
        config.profiles.append(Profile(name: "Pessoal", color: .orange, claudeConfigDir: home.path + "/.claude-pessoal", claudeAccountId: account.id))
        XCTAssertEqual(ClaudeAccountEditor.profilesUsing(account.id, in: config).map(\.name), ["Pessoal"])

        let updated = ClaudeAccountEditor.remove(account.id, from: config, keychain: keychain)
        XCTAssertEqual(updated.claudeAccounts, [])
        XCTAssertNil(updated.profiles[0].claudeAccountId)
        XCTAssertEqual(updated.profiles[0].claudeConfigDir, home.path + "/.claude-pessoal", "the profile keeps its folder")
        XCTAssertNil(keychain.storedValue(account: account.keychainAccount))
    }

    func testSetupTokenOutputIsCapturedAndMasked() {
        var parser = SetupTokenParser()
        _ = parser.consume(Array("Opening browser to sign in…\r\nLogin successful.\r\nYour OAuth token (valid for 1 year):\r\n\r\n\u{1B}[1m\(token)\u{1B}[0m\r\n".utf8))
        XCTAssertEqual(parser.token, token)
        XCTAssertFalse(parser.maskedTranscript.contains(token))
        XCTAssertTrue(parser.maskedTranscript.contains(Redactor.mask))
    }

    // MARK: Migration from config v1 (account = folder)

    func testV1FolderAccountsBecomeProfileFolders() throws {
        let v1 = #"""
        {"version":1,"gitIdentities":[],"githubAccounts":[],"apiKeys":[],
         "claudeAccounts":[
          {"id":"11111111-1111-1111-1111-111111111111","nickname":"Pessoal","color":"orange","configDir":"\#(home.path)/.claude-pessoal"},
          {"id":"22222222-2222-2222-2222-222222222222","nickname":"Trabalho","color":"indigo"}],
         "profiles":[
          {"id":"33333333-3333-3333-3333-333333333333","name":"Pessoal","color":"orange","icon":{"letter":{"_0":"P"}},"claudeAccountId":"11111111-1111-1111-1111-111111111111","apiKeyIds":[]},
          {"id":"44444444-4444-4444-4444-444444444444","name":"Trabalho","color":"indigo","icon":{"letter":{"_0":"T"}},"claudeAccountId":"22222222-2222-2222-2222-222222222222","apiKeyIds":[]},
          {"id":"55555555-5555-5555-5555-555555555555","name":"Sem","color":"red","icon":{"letter":{"_0":"S"}},"apiKeyIds":[]}],
         "settings":{"switchFeedback":"hud","enabledShells":["zsh"],"openAtLogin":true}}
        """#
        let paths = AppPaths(environment: environment)
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        try Data(v1.utf8).write(to: paths.config)

        let config = try XCTUnwrap(try ConfigRepository(environment: environment).load())
        XCTAssertEqual(config.version, 2)
        XCTAssertEqual(config.claudeAccounts, [], "folder accounts are now just folders")
        XCTAssertEqual(config.profiles.map(\.claudeConfigDir), [home.path + "/.claude-pessoal", nil, nil])
        XCTAssertEqual(config.profiles.map(\.claudeAccountId), [nil, nil, nil])
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.root.appendingPathComponent("config.json.v1").path), "v1 kept as a copy")
        XCTAssertEqual(try ConfigRepository(environment: environment).load(), config, "saved migrated; second load is stable")
    }

    func testRepositoryRefusesInvalidConfig() throws {
        let repository = ConfigRepository(environment: environment)
        XCTAssertNil(try repository.load())
        var config = Config()
        config.gitIdentities.append(GitIdentity(nickname: "x", name: "a\nb", email: "a@b.c", color: .red))
        XCTAssertThrowsError(try repository.save(config))
        try repository.save(Config())
        XCTAssertEqual(try repository.load(), Config())
    }
}
