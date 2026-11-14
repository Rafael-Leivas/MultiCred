import Foundation
import XCTest
@testable import MultiCredCore

private actor RecordingRunner: CommandRunner {
    private(set) var commands: [String] = []
    func run(_ request: CommandRequest) async throws -> CommandResult {
        commands.append(request.displayString)
        return CommandResult(exitCode: 0)
    }
}

final class ReadOnlyGuardsTests: SafeTestCase {
    private func request(_ executable: String, _ arguments: [String]) -> CommandRequest {
        CommandRequest(executable: URL(fileURLWithPath: executable), arguments: arguments)
    }

    func testRunnerRejectsEverythingOutsideAllowlist() async throws {
        let inner = RecordingRunner()
        let guarded = ReadOnlyCommandRunner(inner: inner, loginShell: "/bin/zsh")

        let allowed: [CommandRequest] = [
            request("/usr/bin/git", ["--version"]),
            request("/usr/bin/git", ["config", "--global", "--includes", "--get", "user.name"]),
            request("/usr/bin/git", ["config", "--includes", "--show-origin", "--get", "user.email"]),
            request("/opt/homebrew/bin/gh", ["--version"]),
            request("/opt/homebrew/bin/gh", ["auth", "status", "--json", "hosts"]),
            request("/opt/homebrew/bin/gh", ["config", "get", "-h", "github.com", "user"]),
            request("/Users/x/.local/bin/claude", ["--version"]),
            request("/Users/x/.local/bin/claude", ["auth", "status", "--json"]),
            request("/bin/launchctl", ["getenv", "CLAUDE_CONFIG_DIR"]),
            request("/bin/zsh", ["-l", "-i", "-c", "printf '__MULTICRED_PATH__%s__MULTICRED_PATH__' \"$PATH\""]),
        ]
        for command in allowed { _ = try await guarded.run(command) }
        let ran = await inner.commands.count
        XCTAssertEqual(ran, allowed.count)

        let denied: [CommandRequest] = [
            request("/opt/homebrew/bin/gh", ["auth", "switch", "--hostname", "github.com", "--user", "u"]),
            request("/opt/homebrew/bin/gh", ["auth", "status", "--show-token"]),
            request("/opt/homebrew/bin/gh", ["auth", "token"]),
            request("/usr/bin/git", ["config", "--global", "user.name", "x"]),
            request("/usr/bin/git", ["config", "--unset", "user.name"]),
            request("/usr/bin/git", ["config", "--global", "--get", "user.name", "--add", "x"]),
            request("/usr/bin/git", ["commit", "-m", "x"]),
            request("/Users/x/.local/bin/claude", ["auth", "login"]),
            request("/Users/x/.local/bin/claude", ["auth", "logout"]),
            request("/bin/launchctl", ["setenv", "CLAUDE_CONFIG_DIR", "/tmp"]),
            request("/usr/bin/security", ["find-generic-password", "-s", "app.multicred.apikey", "-w"]),
            request("/bin/rm", ["-rf", "/"]),
            request("/bin/zsh", ["-c", "echo hi > ~/.zshrc"]),
            request("/bin/zsh", ["-l", "-i", "-c", "printf '__MULTICRED_PATH__%s__MULTICRED_PATH__' \"$PATH\"; rm -rf ~"]),
            request("/usr/bin/git", ["config", "--system", "--get", "user.name"]),
            request("/usr/bin/git", ["config", "--global", "--get", "user.name", "--file", "/tmp/x"]),
            request("/Users/x/.local/bin/claude", ["auth", "status", "--foo"]),
            request("/opt/homebrew/bin/gh", ["auth", "status", "--hostname", "evil"]),
            request("/bin/launchctl", ["getenv", "A", "B"]),
        ]
        for command in denied {
            do {
                _ = try await guarded.run(command)
                XCTFail("should have been rejected: \(command.displayString)")
            } catch is ReadOnlyViolation {}
        }
        let after = await inner.commands.count
        XCTAssertEqual(after, allowed.count, "rejected commands never reach the real runner")
    }

    func testKeychainAndCredentialStoreAnswerPresenceOnly() throws {
        try keychain.setSecret(Data("sk-secret".utf8), account: UUID().uuidString)
        let account = try XCTUnwrap(keychain.allAccounts().first)
        try claudeStore.writeVault("acct", data: Data("oauth-secret".utf8))

        let readOnlyKeychain = PresenceOnlyKeychain(inner: keychain)
        XCTAssertTrue(try readOnlyKeychain.containsItem(account: account))
        XCTAssertThrowsError(try readOnlyKeychain.setSecret(Data("x".utf8), account: UUID().uuidString))
        XCTAssertThrowsError(try readOnlyKeychain.deleteItem(account: account))
        XCTAssertNotNil(keychain.storedValue(account: account), "nothing was deleted")

        let readOnlyCredentials = PresenceOnlyClaudeCredentialStore(inner: claudeStore)
        XCTAssertTrue(try readOnlyCredentials.hasVaultEntry("acct"))
        XCTAssertFalse(try readOnlyCredentials.hasVaultEntry("missing"))
        XCTAssertThrowsError(try readOnlyCredentials.readVault("acct"))
        XCTAssertThrowsError(try readOnlyCredentials.readFolderItem(configDir: nil))
        XCTAssertThrowsError(try readOnlyCredentials.writeVault("acct", data: Data()))
        XCTAssertThrowsError(try readOnlyCredentials.deleteVault("acct"))
        XCTAssertThrowsError(try readOnlyCredentials.writeFolderItem(configDir: nil, data: Data()))
        XCTAssertThrowsError(try readOnlyCredentials.deleteFolderItem(configDir: nil))
    }

    func testVerifierChecksLoginPresenceWithoutReadingTheSecret() async throws {
        let account = ClaudeAccount(nickname: "Marco", color: .teal, kind: .login)
        let profile = Profile(name: "P", color: .orange)
        let config = Config(claudeAccounts: [account], profiles: [profile])
        try claudeStore.writeVault(account.id.uuidString, data: Data("oauth-secret".utf8))
        let state = ActiveState(profileId: profile.id, appliedClaudeAccountId: account.id)
        runner.on("launchctl", ["getenv"], stdout: "")

        let guardedEnvironment = SystemEnvironment(
            mode: .test, home: home, loginShell: "/bin/zsh", userName: "tester",
            runner: runner,
            keychain: PresenceOnlyKeychain(inner: keychain),
            claudeCredentials: PresenceOnlyClaudeCredentialStore(inner: claudeStore)
        )
        let report = await Verifier(environment: guardedEnvironment, tools: FakeTools(), processes: FixedProcessScanner(sessions: 0))
            .run(config: config, state: state, checkGitHubTokens: false) { _ in .loggedIn(email: nil) }
        let status = report.items.first { $0.id == "claude.login" }?.status
        XCTAssertTrue(status == .ok, "\(String(describing: status))")
    }
}
