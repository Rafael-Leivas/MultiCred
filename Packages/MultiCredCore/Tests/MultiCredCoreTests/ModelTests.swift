import Foundation
import XCTest
@testable import MultiCredCore

final class ClaudePathsTests: SafeTestCase {
    func testKeychainServiceMatchesClaudeCodeNaming() {
        // Values observed in the Phase 1 spike (docs/spikes/claude-config-dir.md).
        XCTAssertEqual(ClaudePaths.keychainService(forConfigDir: nil), "Claude Code-credentials")
        XCTAssertEqual(ClaudePaths.keychainService(forConfigDir: "/Users/rafael_leivas/.claude-pessoal"), "Claude Code-credentials-afe9af63")
        XCTAssertEqual(ClaudePaths.keychainService(forConfigDir: "/Users/rafael_leivas/.claude-pessoal/jobs/e773c694/tmp/claude-spike/config"), "Claude Code-credentials-bd61f705")
    }

    func testCanonicalizationRemovesTildeTrailingSlashAndDots() throws {
        XCTAssertEqual(try ClaudePaths.canonicalConfigDir("~/.claude-work/", environment: environment), home.path + "/.claude-work")
        XCTAssertEqual(try ClaudePaths.canonicalConfigDir("  ~/a/../.claude-x//  ", environment: environment), home.path + "/.claude-x")
    }

    func testDefaultDirectoryMeansNoVariable() throws {
        XCTAssertNil(try ClaudePaths.canonicalConfigDir("~/.claude", environment: environment))
        XCTAssertNil(try ClaudePaths.canonicalConfigDir(home.path + "/.claude/", environment: environment))
    }

    func testRejectsRelativeEmptyAndControlCharacters() {
        XCTAssertThrowsError(try ClaudePaths.canonicalConfigDir("", environment: environment))
        XCTAssertThrowsError(try ClaudePaths.canonicalConfigDir("claude-x", environment: environment))
        XCTAssertThrowsError(try ClaudePaths.canonicalConfigDir("~/.claude-x\nexport X=1", environment: environment))
    }

    func testSuggestedDirectorySlug() {
        XCTAssertEqual(ClaudePaths.suggestedConfigDir(nickname: "Cliente X — Ação", environment: environment), home.path + "/.claude-cliente-x-acao")
        XCTAssertEqual(ClaudePaths.suggestedConfigDir(nickname: "!!!", environment: environment), home.path + "/.claude-conta")
    }
}

final class ValidationTests: XCTestCase {
    private func sampleConfig() -> Config {
        let git = GitIdentity(nickname: "NPU", name: "Rafael Leivas", email: "r@work.example", color: .indigo)
        let gh = GitHubAccount(nickname: "NPU", username: "rafael-npu", color: .indigo)
        let claude = ClaudeAccount(nickname: "NPU", color: .indigo, configDir: nil)
        let key = APIKeyAccount(nickname: "NPU", provider: .openai, color: .indigo)
        let profile = Profile(name: "Trabalho", color: .indigo, gitIdentityId: git.id, githubAccountId: gh.id, claudeAccountId: claude.id, apiKeyIds: [key.id])
        return Config(gitIdentities: [git], githubAccounts: [gh], claudeAccounts: [claude], apiKeys: [key], profiles: [profile])
    }

    func testValidConfigHasNoIssues() {
        XCTAssertEqual(Validation.issues(in: sampleConfig()), [])
    }

    func testNewlinesAndBadEmailAreRejected() {
        var config = sampleConfig()
        config.gitIdentities[0].name = "Evil\n[core]\n\tsshCommand = touch /tmp/x"
        config.gitIdentities[0].email = "not-an-email"
        let issues = Validation.issues(in: config)
        let id = config.gitIdentities[0].id
        XCTAssertTrue(issues.contains(.controlCharacters(owner: id, field: "name")))
        XCTAssertTrue(issues.contains(.invalidEmail(owner: id)))
    }

    func testEnvVarRules() {
        var config = sampleConfig()
        config.apiKeys[0].envVar = "openai key"
        XCTAssertTrue(Validation.issues(in: config).contains(.invalidEnvVar(owner: config.apiKeys[0].id, name: "openai key")))
        config.apiKeys[0].envVar = "PATH"
        XCTAssertTrue(Validation.issues(in: config).contains(.reservedEnvVar(owner: config.apiKeys[0].id, name: "PATH")))
    }

    func testTwoKeysWithSameVariableInOneProfile() {
        var config = sampleConfig()
        let second = APIKeyAccount(nickname: "Pessoal", provider: .openai, color: .orange)
        config.apiKeys.append(second)
        config.profiles[0].apiKeyIds.append(second.id)
        XCTAssertTrue(Validation.issues(in: config).contains(.duplicateEnvVarInProfile(profile: config.profiles[0].id, name: "OPENAI_API_KEY")))
    }

    func testClaudeDirectoriesMustBeCanonicalAndUnique() {
        var config = sampleConfig()
        let trailing = ClaudeAccount(nickname: "X", color: .teal, configDir: "/Users/x/.claude-x/")
        let defaultAgain = ClaudeAccount(nickname: "Y", color: .teal, configDir: nil)
        config.claudeAccounts += [trailing, defaultAgain]
        let issues = Validation.issues(in: config)
        XCTAssertTrue(issues.contains(.invalidClaudeDirectory(owner: trailing.id)))
        XCTAssertTrue(issues.contains(.duplicateClaudeDirectory(owner: defaultAgain.id)))
    }

    func testDanglingReferencesAndBadGitHubUsername() {
        var config = sampleConfig()
        config.profiles[0].claudeAccountId = UUID()
        config.githubAccounts[0].username = "bad user;rm"
        let issues = Validation.issues(in: config)
        XCTAssertTrue(issues.contains(.missingReference(profile: config.profiles[0].id, field: "claude")))
        XCTAssertTrue(issues.contains(.invalidGitHubUsername(owner: config.githubAccounts[0].id)))
    }

    func testConfigRoundTripsThroughJSON() throws {
        let config = sampleConfig()
        let data = try JSONFileStore<Config>.encoder().encode(config)
        XCTAssertEqual(try JSONFileStore<Config>.decoder().decode(Config.self, from: data), config)
    }

    func testManagedEnvVarsAreUniqueAndSorted() {
        var config = sampleConfig()
        config.apiKeys.append(APIKeyAccount(nickname: "G", provider: .gemini, color: .green))
        config.apiKeys.append(APIKeyAccount(nickname: "O2", provider: .openai, color: .green))
        XCTAssertEqual(config.managedEnvVars, ["GEMINI_API_KEY", "OPENAI_API_KEY"])
    }
}
