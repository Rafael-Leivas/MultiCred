import XCTest
@testable import MultiCredCore

/// Live switching (D39): a login account is placed into the profile folder's
/// own credential item, like /login, so open sessions switch too.
final class ClaudeLoginSwitchTests: SafeTestCase {
    private var system: FakeSystem!
    private var config: Config!
    private var personalDir: String!
    private var dev: ClaudeAccount { config.claudeAccounts[0] }
    private var arvor: ClaudeAccount { config.claudeAccounts[1] }
    private var personal: Profile { config.profiles[0] }
    private var work: Profile { config.profiles[1] }

    private func oauth(_ name: String) -> [String: Any] {
        ["accessToken": "sk-ant-oat01-\(name)", "refreshToken": "sk-ant-ort01-\(name)", "expiresAt": 1, "scopes": ["user:inference", "user:profile"]]
    }

    private func json(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func object(_ data: Data?) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(data)) as? [String: Any])
    }

    private func folderAccessToken(_ dir: String?) throws -> String? {
        (try object(claudeStore.readFolderItem(configDir: dir))["claudeAiOauth"] as? [String: Any])?["accessToken"] as? String
    }

    private func displayedEmail(_ dir: String?) throws -> String? {
        let file = ClaudeAccountFiles.stateFile(for: ClaudeFolder.ownLogin(dir), environment: environment)
        return (try object(Data(contentsOf: file))["oauthAccount"] as? [String: Any])?["emailAddress"] as? String
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        system = FakeSystem()
        system.install(on: runner)
        personalDir = home.path + "/.claude-pessoal"
        try FileManager.default.createDirectory(atPath: personalDir, withIntermediateDirectories: true)

        // The personal folder is logged in on its own, and has an MCP login.
        try claudeStore.writeFolderItem(configDir: personalDir, data: json(["claudeAiOauth": oauth("own"), "mcpOAuth": ["notion": ["accessToken": "mcp"]]]))
        try json(["oauthAccount": ["emailAddress": "own@x.com"], "numStartups": 7]).write(to: URL(fileURLWithPath: personalDir + "/.claude.json"))
        // ~/.claude (work profile) is logged in on its own too.
        try claudeStore.writeFolderItem(configDir: nil, data: json(["claudeAiOauth": oauth("work-own")]))
        try json(["oauthAccount": ["emailAddress": "work@x.com"]]).write(to: home.appendingPathComponent(".claude.json"))

        let dev = ClaudeAccount(nickname: "Dev HINC", email: "dev@x.com", color: .blue, kind: .login)
        let arvor = ClaudeAccount(nickname: "Arvor", email: "arvor@x.com", color: .teal, kind: .login)
        let switcher = ClaudeLoginSwitcher(environment: environment, store: claudeStore)
        try switcher.storeNewAccount(dev.id, record: ClaudeLoginRecord(oauth: json(oauth("dev")), account: json(["emailAddress": "dev@x.com"])))
        try switcher.storeNewAccount(arvor.id, record: ClaudeLoginRecord(oauth: json(oauth("arvor")), account: json(["emailAddress": "arvor@x.com"])))

        let git = GitIdentity(nickname: "P", name: "R", email: "r@x.com", color: .orange)
        config = Config(
            gitIdentities: [git],
            claudeAccounts: [dev, arvor],
            profiles: [
                Profile(name: "Pessoal", color: .orange, gitIdentityId: git.id, claudeConfigDir: personalDir),
                Profile(name: "Trabalho", color: .indigo, gitIdentityId: git.id, claudeConfigDir: nil),
            ]
        )
    }

    private func engine() -> SwitchEngine { SwitchEngine(environment: environment, tools: FakeTools()) }

    func testClaudeOnlySwitchPutsTheLoginIntoTheFolderItemKeepingEverythingElse() async throws {
        let engine = engine()
        _ = try await engine.switchProfile(personal.id, in: config)
        let result = try await engine.switchClaudeOnly(to: dev.id, in: config)

        XCTAssertEqual(result.appliedSteps, [.claudeLogin, .envFiles, .state])
        XCTAssertEqual(result.state.appliedClaudeAccountId, dev.id)
        XCTAssertEqual(try folderAccessToken(personalDir), "sk-ant-oat01-dev")
        XCTAssertNotNil(try object(claudeStore.readFolderItem(configDir: personalDir))["mcpOAuth"], "MCP logins are kept")
        XCTAssertEqual(try displayedEmail(personalDir), "dev@x.com", "Claude Code shows the right account")
        XCTAssertEqual(try object(Data(contentsOf: URL(fileURLWithPath: personalDir + "/.claude.json")))["numStartups"] as? Int, 7)
        XCTAssertEqual(try folderAccessToken(nil), "sk-ant-oat01-work-own", "other folders untouched")
        XCTAssertFalse(try read(AppPaths(environment: environment).envSh).contains("CLAUDE_CODE_OAUTH_TOKEN=\"$("), "no env token for login accounts")
        // The folder's own login was kept to come back to.
        XCTAssertNotNil(try claudeStore.readVault(ClaudeLoginSwitcher.ownLoginKey(personalDir)))
    }

    func testRotatedTokensAreSavedBackAndTheOwnLoginComesBack() async throws {
        let engine = engine()
        _ = try await engine.switchProfile(personal.id, in: config)
        _ = try await engine.switchClaudeOnly(to: dev.id, in: config)
        // Claude Code refreshes while dev is live: the folder now has newer tokens.
        try claudeStore.writeFolderItem(configDir: personalDir, data: json(["claudeAiOauth": oauth("dev-rotated"), "mcpOAuth": [:]]))

        _ = try await engine.switchClaudeOnly(to: arvor.id, in: config)
        XCTAssertEqual(try folderAccessToken(personalDir), "sk-ant-oat01-arvor")
        let saved = try object(claudeStore.readVault(dev.id.uuidString))
        XCTAssertEqual((saved["claudeAiOauth"] as? [String: Any])?["accessToken"] as? String, "sk-ant-oat01-dev-rotated")

        // "Login da pasta" puts the folder's original login back.
        let back = try await engine.switchClaudeOnly(to: ClaudeFolder.override(for: nil, profile: personal), in: config)
        XCTAssertNil(back.state.appliedClaudeAccountId)
        XCTAssertEqual(try folderAccessToken(personalDir), "sk-ant-oat01-own")
        XCTAssertEqual(try displayedEmail(personalDir), "own@x.com")
    }

    func testAnAccountLivesInOneFolderAtATime() async throws {
        let engine = engine()
        _ = try await engine.switchProfile(personal.id, in: config)
        _ = try await engine.switchClaudeOnly(to: dev.id, in: config)

        config.profiles[1].claudeAccountId = dev.id
        _ = try await engine.switchProfile(work.id, in: config)
        XCTAssertEqual(try folderAccessToken(nil), "sk-ant-oat01-dev", "dev moved to ~/.claude")
        XCTAssertEqual(try folderAccessToken(personalDir), "sk-ant-oat01-own", "the personal folder got its own login back")
        XCTAssertEqual(try displayedEmail(personalDir), "own@x.com")
    }

    /// The user's case: Dev HINC was put into a test folder that never had a
    /// login of its own, then asked for in the work profile (~/.claude).
    func testMovingAnAccountOutOfAFolderThatNeverHadItsOwnLogin() async throws {
        let testDir = home.path + "/.claude-teste"
        try FileManager.default.createDirectory(atPath: testDir, withIntermediateDirectories: true)
        config.profiles.append(Profile(name: "Teste", color: .graphite, gitIdentityId: config.gitIdentities[0].id, claudeConfigDir: testDir, claudeAccountId: dev.id))
        let engine = engine()
        _ = try await engine.switchProfile(config.profiles[2].id, in: config)
        XCTAssertEqual(try folderAccessToken(testDir), "sk-ant-oat01-dev")

        _ = try await engine.switchProfile(work.id, in: config)
        let result = try await engine.switchClaudeOnly(to: dev.id, in: config)
        XCTAssertEqual(result.state.appliedClaudeAccountId, dev.id)
        XCTAssertEqual(try folderAccessToken(nil), "sk-ant-oat01-dev", "dev moved to ~/.claude")
        XCTAssertNil(try object(claudeStore.readFolderItem(configDir: testDir))["claudeAiOauth"], "the test folder is back to no login, as it was")
        XCTAssertNil(try? displayedEmail(testDir))

        // And back: ~/.claude gets its own login again.
        _ = try await engine.switchClaudeOnly(to: ClaudeFolder.override(for: nil, profile: work), in: config)
        XCTAssertEqual(try folderAccessToken(nil), "sk-ant-oat01-work-own")
    }

    func testAFailedSwitchPutsTheOldLoginBack() async throws {
        let engine = engine()
        _ = try await engine.switchProfile(personal.id, in: config)
        let itemBefore = try claudeStore.readFolderItem(configDir: personalDir)
        try FileManager.default.createDirectory(at: AppPaths(environment: environment).envSh.appendingPathExtension("x"), withIntermediateDirectories: true)
        try FileManager.default.removeItem(at: AppPaths(environment: environment).envSh)
        try FileManager.default.createDirectory(at: AppPaths(environment: environment).envSh, withIntermediateDirectories: true)

        do {
            _ = try await engine.switchClaudeOnly(to: dev.id, in: config)
            XCTFail("env files step should fail")
        } catch let SwitchError.stepFailed(step, _, rollback) {
            XCTAssertEqual(step, .envFiles)
            XCTAssertEqual(rollback, .complete)
        }
        XCTAssertEqual(try claudeStore.readFolderItem(configDir: personalDir), itemBefore)
        XCTAssertEqual(try displayedEmail(personalDir), "own@x.com")
        XCTAssertNil(ClaudeLoginSwitcher(environment: environment, store: claudeStore).occupancy().account(in: personalDir))
    }

    func testMissingLoginIsAPreflightFailure() async throws {
        try claudeStore.deleteVault(dev.id.uuidString)
        _ = try await engine().switchProfile(personal.id, in: config)
        do {
            _ = try await engine().switchClaudeOnly(to: dev.id, in: config)
            XCTFail("expected preflight failure")
        } catch {
            XCTAssertEqual(error as? SwitchError, .preflight(.claudeLoginMissing("Dev HINC")))
        }
    }

    func testRemovingALiveAccountGivesTheFolderItsOwnLoginBack() async throws {
        let engine = engine()
        _ = try await engine.switchProfile(personal.id, in: config)
        _ = try await engine.switchClaudeOnly(to: dev.id, in: config)
        let switcher = ClaudeLoginSwitcher(environment: environment, store: claudeStore)
        try switcher.removeAccount(dev.id)
        XCTAssertEqual(try folderAccessToken(personalDir), "sk-ant-oat01-own")
        XCTAssertNil(try claudeStore.readVault(dev.id.uuidString))
    }

    func testCaptureReadsANewLoginFromAThrowawayFolder() throws {
        let scratch = home.path + "/scratch-login"
        try FileManager.default.createDirectory(atPath: scratch, withIntermediateDirectories: true)
        try claudeStore.writeFolderItem(configDir: scratch, data: json(["claudeAiOauth": oauth("new")]))
        try json(["oauthAccount": ["emailAddress": "new@x.com"]]).write(to: URL(fileURLWithPath: scratch + "/.claude.json"))
        let record = try ClaudeLoginSwitcher(environment: environment, store: claudeStore).capture(fromScratch: scratch)
        XCTAssertEqual(record.email, "new@x.com")
        XCTAssertEqual(try object(record.oauth)["accessToken"] as? String, "sk-ant-oat01-new")
    }

    func testSecurityLineQuotesServiceNamesWithSpaces() {
        XCTAssertEqual(
            SecurityToolRunner.interactiveLine(["add-generic-password", "-U", "-s", "Claude Code-credentials-afe9af63", "-a", "me", "-X", "7b7d"]),
            "add-generic-password -U -s \"Claude Code-credentials-afe9af63\" -a me -X 7b7d\n"
        )
    }
}
