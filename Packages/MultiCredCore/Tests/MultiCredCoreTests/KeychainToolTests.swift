import XCTest
@testable import MultiCredCore

/// Items are created by `security` so the shell reads them without a password
/// prompt; the secret must never appear in the process arguments.
final class KeychainToolTests: XCTestCase {
    func testAddSendsTheSecretAsHexOnStdinOnly() throws {
        let secret = Data("sk-ant-oat01-secret value".utf8)
        let command = SecurityToolCommand.add(service: "app.multicred.apikey", account: "11111111-1111-1111-1111-111111111111", label: "MultiCred", secret: secret)
        XCTAssertEqual(command.arguments, ["-i"])
        let line = try XCTUnwrap(command.standardInput.map { String(decoding: $0, as: UTF8.self) })
        XCTAssertEqual(line, "add-generic-password -U -s app.multicred.apikey -a 11111111-1111-1111-1111-111111111111 -l MultiCred -X 736b2d616e742d6f617430312d7365637265742076616c7565\n")
        XCTAssertFalse(line.contains("secret value"))
        XCTAssertFalse(command.arguments.joined().contains("736b"))
    }

    func testDeleteHasNoSecret() {
        let command = SecurityToolCommand.delete(service: "s", account: "a")
        XCTAssertEqual(command.arguments, ["delete-generic-password", "-s", "s", "-a", "a"])
        XCTAssertNil(command.standardInput)
    }
}

final class LegacyKeychainItemVerifyTests: SafeTestCase {
    func testLegacyTokenItemIsAWarningWithANewTokenFix() async throws {
        let marco = ClaudeAccount(nickname: "Marco", color: .teal)
        let profile = Profile(name: "P", color: .orange)
        let config = Config(claudeAccounts: [marco], profiles: [profile])
        try keychain.setSecret(Data("sk-ant-oat01-x".utf8), account: marco.keychainAccount)
        runner.on("launchctl", ["getenv"], stdout: "")
        runner.on("launchctl", ["unsetenv"])
        let engine = SwitchEngine(environment: environment, tools: FakeTools())
        _ = try await engine.switchProfile(profile.id, in: config)
        let state = try await engine.switchClaudeOnly(to: marco.id, in: config).state
        keychain.markLegacy(account: marco.keychainAccount)  // as an item left by an older build

        let report = await Verifier(environment: environment, tools: FakeTools(), processes: FixedProcessScanner(sessions: 0))
            .run(config: config, state: state, checkGitHubTokens: false) { _ in .loggedOut }
        let item = report.items.first { $0.id == "claude.login" }
        XCTAssertEqual(item?.status, .warning)
        XCTAssertEqual(item?.fix, .loginClaude(marco.id))

        try keychain.setSecret(Data("sk-ant-oat01-y".utf8), account: marco.keychainAccount)
        XCTAssertFalse(try keychain.isLegacyItem(account: marco.keychainAccount), "saving again moves it to the new scheme")
    }
}
