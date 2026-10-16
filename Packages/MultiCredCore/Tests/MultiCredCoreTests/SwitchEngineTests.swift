import Foundation
import XCTest
@testable import MultiCredCore

/// Stateful stand-in for gh and launchctl behind `FakeCommandRunner`.
final class FakeSystem: @unchecked Sendable {
    private let lock = NSLock()
    var ghLogins: [(login: String, state: String)] = [("rafael-npu", "success"), ("rafaelbleivas", "success")]
    var ghActive = "rafael-npu"
    var launchdClaude: String?
    var failGHSwitchTo: String?
    var failLaunchctlSet = false
    var failLaunchctlUnset = false
    var ghSwitchDelay: TimeInterval = 0

    func locked<T>(_ body: () -> T) -> T { lock.withLock(body) }

    func install(on runner: FakeCommandRunner) {
        runner.on("gh", ["auth", "status", "--json", "hosts"]) { [self] _ in
            let entries = locked {
                ghLogins.map { #"{"host":"github.com","login":"\#($0.login)","active":\#($0.login == ghActive),"state":"\#($0.state)","tokenSource":"keyring","gitProtocol":"https"}"# }
            }
            return CommandResult(exitCode: 0, standardOutput: Data(#"{"hosts":{"github.com":[\#(entries.joined(separator: ","))]}}"#.utf8))
        }
        runner.on("gh", ["config", "get", "-h", "github.com", "user"]) { [self] _ in
            CommandResult(exitCode: 0, standardOutput: Data(locked { ghActive + "\n" }.utf8))
        }
        runner.on("gh", ["auth", "switch"]) { [self] request in
            let user = request.arguments.last!
            if ghSwitchDelay > 0 { Thread.sleep(forTimeInterval: ghSwitchDelay) }
            return locked {
                if user == failGHSwitchTo { return CommandResult(exitCode: 1, standardError: Data("gh: keyring locked".utf8)) }
                guard ghLogins.contains(where: { $0.login == user }) else {
                    return CommandResult(exitCode: 1, standardError: Data("not logged in to github.com account \(user)".utf8))
                }
                ghActive = user
                return CommandResult(exitCode: 0)
            }
        }
        runner.on("launchctl", ["getenv"]) { [self] _ in
            CommandResult(exitCode: 0, standardOutput: Data(locked { launchdClaude.map { $0 + "\n" } ?? "" }.utf8))
        }
        runner.on("launchctl", ["setenv"]) { [self] request in
            locked {
                if failLaunchctlSet { return CommandResult(exitCode: 1, standardError: Data("launchctl failed".utf8)) }
                launchdClaude = request.arguments[2]
                return CommandResult(exitCode: 0)
            }
        }
        runner.on("launchctl", ["unsetenv"]) { [self] _ in
            locked {
                if failLaunchctlUnset { return CommandResult(exitCode: 1, standardError: Data("launchctl failed".utf8)) }
                launchdClaude = nil
                return CommandResult(exitCode: 0)
            }
        }
    }
}

struct FakeTools: ToolLocating {
    var installed: Set<Tool> = [.git, .gh, .claude]
    func locate(_ tool: Tool) async -> URL? { installed.contains(tool) ? URL(fileURLWithPath: "/fake/bin/\(tool.rawValue)") : nil }
    func searchDirectories() async -> [String] { ["/fake/bin"] }
}

final class SwitchEngineTests: SafeTestCase {
    private var system: FakeSystem!
    private var paths: AppPaths!
    private var config: Config!
    private var work: Profile!
    private var personal: Profile!
    private var claudePersonalDir: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        system = FakeSystem()
        system.install(on: runner)
        paths = AppPaths(environment: environment)

        claudePersonalDir = home.path + "/.claude-pessoal"
        try FileManager.default.createDirectory(atPath: claudePersonalDir, withIntermediateDirectories: true)

        let gitWork = GitIdentity(nickname: "NPU", name: "Rafael Leivas", email: "r@work.example", color: .indigo)
        let gitPersonal = GitIdentity(nickname: "Pessoal", name: "Rafael B. Leivas", email: "r@gmail.com", sshKeyPath: "~/.ssh/id_pessoal", color: .orange)
        let ghWork = GitHubAccount(nickname: "NPU", username: "rafael-npu", color: .indigo)
        let ghPersonal = GitHubAccount(nickname: "Pessoal", username: "rafaelbleivas", color: .orange)
        // A credential-only Claude account (token), as for "use Marco's account".
        let marco = ClaudeAccount(nickname: "Marco", email: "marco@x.com", color: .teal)
        let openAI = APIKeyAccount(nickname: "NPU", provider: .openai, color: .indigo)
        let gemini = APIKeyAccount(nickname: "Pessoal", provider: .gemini, color: .orange)
        try keychain.setSecret(Data("sk".utf8), account: openAI.keychainAccount)
        try keychain.setSecret(Data("g".utf8), account: gemini.keychainAccount)
        try keychain.setSecret(Data("sk-ant-oat01-marco".utf8), account: marco.keychainAccount)

        // Work uses ~/.claude (default); Personal uses its own folder. Both log in
        // with the folder's own login.
        work = Profile(name: "Trabalho NPU", color: .indigo, gitIdentityId: gitWork.id, githubAccountId: ghWork.id, claudeConfigDir: nil, apiKeyIds: [openAI.id])
        personal = Profile(name: "Pessoal", color: .orange, gitIdentityId: gitPersonal.id, githubAccountId: ghPersonal.id, claudeConfigDir: claudePersonalDir, apiKeyIds: [gemini.id])
        config = Config(
            gitIdentities: [gitWork, gitPersonal],
            githubAccounts: [ghWork, ghPersonal],
            claudeAccounts: [marco],
            apiKeys: [openAI, gemini],
            profiles: [work, personal]
        )
    }

    private var marco: ClaudeAccount { config.claudeAccounts[0] }

    private func engine(tools: FakeTools = FakeTools()) -> SwitchEngine {
        SwitchEngine(environment: environment, tools: tools)
    }

    private func snapshotFiles() -> [String: Data?] {
        [paths.gitconfig, paths.envSh, paths.envFish, paths.state, paths.generation].reduce(into: [:]) {
            $0[$1.lastPathComponent] = try? Data(contentsOf: $1)
        }
    }

    private func switchError(_ body: () async throws -> SwitchResult) async -> SwitchError? {
        do { _ = try await body(); return nil } catch { return error as? SwitchError }
    }

    private func mutatingCommands() -> [String] {
        runner.requests.map(\.arguments).filter { $0.starts(with: ["auth", "switch"]) || ["setenv", "unsetenv"].contains($0.first ?? "") }.map { $0.joined(separator: " ") }
    }

    // MARK: Happy paths

    func testSwitchToPersonalAppliesEverything() async throws {
        let result = try await engine().switchProfile(personal.id, in: config)

        XCTAssertEqual(result.appliedSteps, [.git, .github, .launchd, .claudeSettings, .envFiles, .state])
        XCTAssertEqual(system.ghActive, "rafaelbleivas")
        XCTAssertEqual(system.launchdClaude, claudePersonalDir)

        let gitconfig = try read(paths.gitconfig)
        XCTAssertTrue(gitconfig.contains("email = \"r@gmail.com\""))
        XCTAssertTrue(gitconfig.contains("sshCommand = \"ssh -i '\(home.path)/.ssh/id_pessoal' -o IdentitiesOnly=yes\""))

        let envSh = try read(paths.envSh)
        XCTAssertTrue(envSh.contains("unset CLAUDE_CODE_OAUTH_TOKEN GEMINI_API_KEY OPENAI_API_KEY"))
        XCTAssertTrue(envSh.contains("export CLAUDE_CONFIG_DIR='\(claudePersonalDir!)'"))
        XCTAssertTrue(envSh.contains("GEMINI_API_KEY=\"$("))
        XCTAssertFalse(envSh.contains("OPENAI_API_KEY=\"$("))

        XCTAssertEqual(try read(paths.generation), "1\n")
        let state = try StateStore(paths: paths).load()
        XCTAssertEqual(state.profileId, personal.id)
        XCTAssertNil(state.claudeOverrideId)
        XCTAssertEqual(state.generation, 1)
        XCTAssertEqual(try mode(of: paths.state), 0o600)
    }

    func testDefaultClaudeAccountUnsetsTheVariable() async throws {
        system.launchdClaude = "/somewhere/else"
        _ = try await engine().switchProfile(work.id, in: config)
        XCTAssertNil(system.launchdClaude)
        XCTAssertTrue(try read(paths.envSh).contains("unset CLAUDE_CONFIG_DIR"))
    }

    func testAlreadyActiveGitHubAccountIsNotSwitchedAgain() async throws {
        _ = try await engine().switchProfile(work.id, in: config)
        XCTAssertFalse(mutatingCommands().contains { $0.hasPrefix("auth switch") })
    }

    func testProfileWithoutGitHubStillAppliesItsClaudeFolder() async throws {
        system.launchdClaude = claudePersonalDir
        var bare = Profile(name: "Só git", color: .green, gitIdentityId: config.gitIdentities[0].id)
        bare.apiKeyIds = []
        config.profiles.append(bare)
        let result = try await engine().switchProfile(bare.id, in: config)
        XCTAssertEqual(result.appliedSteps, [.git, .launchd, .envFiles, .state])
        XCTAssertFalse(mutatingCommands().contains { $0.hasPrefix("auth switch") })
        XCTAssertNil(system.launchdClaude, "the profile's folder (default ~/.claude) is applied")
        XCTAssertTrue(try read(paths.envSh).contains("unset CLAUDE_CONFIG_DIR"))
    }

    /// The user's case: personal profile, then "use Marco's account". Agents,
    /// skills and chats (the folder) stay; only the credential changes.
    func testClaudeOnlySwitchChangesTheTokenNotTheFolder() async throws {
        let engine = engine()
        _ = try await engine.switchProfile(personal.id, in: config)
        let gitBefore = try read(paths.gitconfig)
        let commandsBefore = runner.requests.count

        let result = try await engine.switchClaudeOnly(to: marco.id, in: config)
        XCTAssertEqual(result.appliedSteps, [.envFiles, .state], "no launchd change: the folder stays")
        XCTAssertEqual(result.state.profileId, personal.id)
        XCTAssertEqual(result.state.claudeOverrideId, marco.id)
        XCTAssertEqual(result.state.appliedClaudeAccountId, marco.id)
        XCTAssertEqual(system.launchdClaude, claudePersonalDir)
        XCTAssertEqual(try read(paths.gitconfig), gitBefore)
        XCTAssertFalse(runner.requests.dropFirst(commandsBefore).contains { ["gh", "launchctl"].contains($0.executable.lastPathComponent) })

        let envSh = try read(paths.envSh)
        XCTAssertTrue(envSh.contains("export CLAUDE_CONFIG_DIR='\(claudePersonalDir!)'"), "same folder")
        XCTAssertTrue(envSh.contains("CLAUDE_CODE_OAUTH_TOKEN=\"$('/usr/bin/security' find-generic-password -s 'app.multicred.apikey' -a '\(marco.keychainAccount)' -w"))
        XCTAssertFalse(envSh.contains("sk-ant-oat01-marco"), "the token itself never goes into the file")
        XCTAssertTrue(envSh.contains("GEMINI_API_KEY=\"$("), "API keys still follow the profile")

        let reapplied = try await engine.reapplyActiveProfile(in: config)
        XCTAssertEqual(reapplied?.state.claudeOverrideId, marco.id, "reapply at login keeps the account")

        // Back to the folder's own login; the token variable is unset.
        let back = try await engine.switchClaudeOnly(to: nil, in: config)
        XCTAssertNil(back.state.appliedClaudeAccountId)
        XCTAssertFalse(try read(paths.envSh).contains("CLAUDE_CODE_OAUTH_TOKEN=\"$("))
        XCTAssertTrue(try read(paths.envSh).contains("unset CLAUDE_CODE_OAUTH_TOKEN GEMINI_API_KEY OPENAI_API_KEY"))
    }

    func testProfileWithATokenAccountUsesItAndNextProfileClearsIt() async throws {
        config.profiles[1].claudeAccountId = marco.id
        let engine = engine()
        let first = try await engine.switchProfile(config.profiles[1].id, in: config)
        XCTAssertEqual(first.state.appliedClaudeAccountId, marco.id)
        XCTAssertTrue(try read(paths.envSh).contains("CLAUDE_CODE_OAUTH_TOKEN=\"$("))

        let second = try await engine.switchProfile(work.id, in: config)
        XCTAssertNil(second.state.appliedClaudeAccountId)
        XCTAssertFalse(try read(paths.envSh).contains("CLAUDE_CODE_OAUTH_TOKEN=\"$("))
    }

    func testFolderLoginOverrideBeatsAProfileTokenAccount() async throws {
        config.profiles[1].claudeAccountId = marco.id
        let engine = engine()
        _ = try await engine.switchProfile(config.profiles[1].id, in: config)

        let override = ClaudeFolder.override(for: nil, profile: config.profiles[1])
        XCTAssertEqual(override, ClaudeFolder.ownLoginOverride)
        let result = try await engine.switchClaudeOnly(to: override, in: config)
        XCTAssertNil(result.state.appliedClaudeAccountId)
        XCTAssertFalse(try read(paths.envSh).contains("CLAUDE_CODE_OAUTH_TOKEN=\"$("))
        let reapplied = try await engine.reapplyActiveProfile(in: config)
        XCTAssertNil(reapplied?.state.appliedClaudeAccountId, "kept at login")

        XCTAssertNil(ClaudeFolder.override(for: marco.id, profile: config.profiles[1]), "the profile default needs no override")
    }

    func testReapplyDropsAnOverrideForARemovedAccount() async throws {
        let engine = engine()
        _ = try await engine.switchProfile(personal.id, in: config)
        _ = try await engine.switchClaudeOnly(to: marco.id, in: config)
        config.claudeAccounts = []  // e.g. removed by the v1 → v2 migration

        let result = try await engine.reapplyActiveProfile(in: config)
        XCTAssertEqual(result?.state.profileId, personal.id)
        XCTAssertNil(result?.state.claudeOverrideId)
        XCTAssertNil(result?.state.appliedClaudeAccountId)
    }

    /// The user's case: co-author off for one GitHub account, on for the other.
    func testClaudeCoAuthorFollowsTheProfilesGitHubAccount() async throws {
        let settings = URL(fileURLWithPath: claudePersonalDir).appendingPathComponent("settings.json")
        try Data(#"{"model":"opus"}"#.utf8).write(to: settings)
        config.githubAccounts[1].claudeCoAuthor = false  // personal GitHub account

        let engine = engine()
        _ = try await engine.switchProfile(personal.id, in: config)
        let written = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any])
        XCTAssertEqual(written["attribution"] as? [String: String], ["commit": "", "pr": ""])
        XCTAssertEqual(written["model"] as? String, "opus", "the rest of settings.json is kept")
        XCTAssertEqual(try read(settings.appendingPathExtension("multicred-backup")), #"{"model":"opus"}"#, "original kept once")

        // Switching only the Claude account never touches settings.json.
        let before = try Data(contentsOf: settings)
        _ = try await engine.switchClaudeOnly(to: marco.id, in: config)
        XCTAssertEqual(try Data(contentsOf: settings), before)

        // Opting back in removes only what MultiCred wrote.
        config.githubAccounts[1].claudeCoAuthor = true
        _ = try await engine.switchProfile(personal.id, in: config)
        let restored = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any])
        XCTAssertNil(restored["attribution"])
        XCTAssertEqual(restored["model"] as? String, "opus")
    }

    func testCoAuthorChangeIsRolledBackWhenALaterStepFails() async throws {
        config.githubAccounts[1].claudeCoAuthor = false
        let settings = URL(fileURLWithPath: claudePersonalDir).appendingPathComponent("settings.json")
        let tools = FakeTools()
        // Make the env files step fail: its target is a directory.
        try FileManager.default.createDirectory(at: paths.envSh, withIntermediateDirectories: true)
        let error = await switchError { try await self.engine(tools: tools).switchProfile(self.personal.id, in: self.config) }
        guard case .stepFailed(.envFiles, _, .complete)? = error else { return XCTFail("\(String(describing: error))") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: settings.path), "the new settings.json was removed again")
    }

    /// The user's case: a token saved by an older build would make the shell
    /// fall back silently to the folder's login; the switch must say so instead.
    func testLegacyTokenFailsTheSwitchInsteadOfFallingBackSilently() async throws {
        keychain.markLegacy(account: marco.keychainAccount)
        _ = try await engine().switchProfile(personal.id, in: config)
        let before = try read(paths.envSh)
        let error = await switchError { try await self.engine().switchClaudeOnly(to: self.marco.id, in: self.config) }
        XCTAssertEqual(error, .preflight(.claudeTokenNeedsRefresh("Marco")))
        XCTAssertEqual(try read(paths.envSh), before, "nothing changed")
    }

    func testMissingTokenIsAPreflightFailure() async throws {
        try keychain.deleteItem(account: marco.keychainAccount)
        _ = try await engine().switchProfile(personal.id, in: config)
        let error = await switchError { try await self.engine().switchClaudeOnly(to: self.marco.id, in: self.config) }
        XCTAssertEqual(error, .preflight(.claudeTokenMissing("Marco")))
    }

    func testGenerationIncreasesAndActivatedAtOnlyChangesOnProfileSwitch() async throws {
        let engine = engine()
        let first = try await engine.switchProfile(work.id, in: config)
        let second = try await engine.switchClaudeOnly(to: marco.id, in: config)
        XCTAssertEqual(first.state.generation, 1)
        XCTAssertEqual(second.state.generation, 2)
        XCTAssertEqual(second.state.activatedAt, first.state.activatedAt)
    }

    func testReapplyWithoutActiveProfileDoesNothing() async throws {
        let result = try await engine().reapplyActiveProfile(in: config)
        XCTAssertNil(result)
        XCTAssertTrue(runner.requests.isEmpty)
    }

    // MARK: Preflight (nothing may change)

    func testPreflightFailuresChangeNothing() async throws {
        try FileManager.default.removeItem(atPath: claudePersonalDir)
        var error = await switchError { try await self.engine().switchProfile(self.personal.id, in: self.config) }
        XCTAssertEqual(error, .preflight(.claudeDirectoryMissing(claudePersonalDir)))

        try FileManager.default.createDirectory(atPath: claudePersonalDir, withIntermediateDirectories: true)
        try keychain.deleteItem(account: config.apiKeys[1].keychainAccount)
        error = await switchError { try await self.engine().switchProfile(self.personal.id, in: self.config) }
        XCTAssertEqual(error, .preflight(.apiKeyMissing(nickname: "Pessoal", envVar: "GEMINI_API_KEY")))

        error = await switchError { try await self.engine(tools: FakeTools(installed: [.git])).switchProfile(self.personal.id, in: self.config) }
        XCTAssertEqual(error, .preflight(.toolMissing(.gh)))

        error = await switchError { try await self.engine().switchProfile(UUID(), in: self.config) }
        XCTAssertEqual(error, .preflight(.profileNotFound))

        XCTAssertEqual(mutatingCommands(), [])
        XCTAssertTrue(snapshotFiles().values.allSatisfy { $0 == nil }, "no file may be written by a failed preflight")
    }

    /// Regression: `gh auth status` tests tokens over the network, so using it on
    /// the switch path made switching slow and impossible offline.
    func testSwitchNeverRunsTheNetworkBoundGitHubStatus() async throws {
        _ = try await engine().switchProfile(personal.id, in: config)
        XCTAssertFalse(runner.requests.contains { $0.arguments.starts(with: ["auth", "status"]) })
    }

    func testAccountUnknownToGitHubCLIFailsAtGitHubAndRollsBackGit() async throws {
        let engine = engine()
        _ = try await engine.switchProfile(work.id, in: config)
        let before = snapshotFiles()
        system.ghLogins = [("rafael-npu", "success")]

        let error = await switchError { try await engine.switchProfile(self.personal.id, in: self.config) }
        guard case let .stepFailed(step, reason, rollback) = error else { return XCTFail("\(String(describing: error))") }
        XCTAssertEqual(step, .github)
        XCTAssertTrue(reason.contains("not logged in"), reason)
        XCTAssertEqual(rollback, .complete)
        XCTAssertEqual(snapshotFiles(), before)
    }

    func testInvalidConfigurationIsRejectedBeforeAnything() async throws {
        config.gitIdentities[0].email = "x\ny"
        let error = await switchError { try await self.engine().switchProfile(self.work.id, in: self.config) }
        guard case .invalidConfiguration = error else { return XCTFail("\(String(describing: error))") }
        XCTAssertTrue(runner.requests.isEmpty)
    }

    // MARK: Rollback

    /// The "2am Friday" test: A applied, switch to B fails midway, A is intact byte for byte.
    func testFailureAtGitHubRestoresPreviousProfileExactly() async throws {
        let engine = engine()
        _ = try await engine.switchProfile(work.id, in: config)
        let before = snapshotFiles()
        let launchdBefore = system.launchdClaude

        system.failGHSwitchTo = "rafaelbleivas"
        let error = await switchError { try await engine.switchProfile(self.personal.id, in: self.config) }

        guard case let .stepFailed(step, reason, rollback) = error else { return XCTFail("\(String(describing: error))") }
        XCTAssertEqual(step, .github)
        XCTAssertTrue(reason.contains("keyring locked"))
        XCTAssertEqual(rollback, .complete)
        XCTAssertEqual(snapshotFiles(), before)
        XCTAssertEqual(system.ghActive, "rafael-npu")
        XCTAssertEqual(system.launchdClaude, launchdBefore)
        let stateAfter = try await engine.currentState()
        XCTAssertEqual(stateAfter.profileId, work.id)
    }

    func testFailureAtLaunchdUndoesGitHubAndGit() async throws {
        let engine = engine()
        _ = try await engine.switchProfile(work.id, in: config)
        let before = snapshotFiles()

        system.failLaunchctlSet = true
        let error = await switchError { try await engine.switchProfile(self.personal.id, in: self.config) }
        guard case .stepFailed(.launchd, _, .complete) = error else { return XCTFail("\(String(describing: error))") }
        XCTAssertEqual(system.ghActive, "rafael-npu", "gh switched back")
        XCTAssertEqual(snapshotFiles(), before)
    }

    func testFailureWritingEnvFilesUndoesLaunchdGitHubAndGit() async throws {
        let engine = engine()
        _ = try await engine.switchProfile(work.id, in: config)
        let before = snapshotFiles()

        // A directory where env.fish should be makes the second write fail.
        try FileManager.default.removeItem(at: paths.envFish)
        try FileManager.default.createDirectory(at: paths.envFish, withIntermediateDirectories: true)

        let error = await switchError { try await engine.switchProfile(self.personal.id, in: self.config) }
        guard case .stepFailed(.envFiles, _, .complete) = error else { return XCTFail("\(String(describing: error))") }
        XCTAssertNil(system.launchdClaude, "launchd back to the default account")
        XCTAssertEqual(system.ghActive, "rafael-npu")
        XCTAssertEqual(try Data(contentsOf: paths.envSh), before["env.sh"]!, "env.sh restored after partial write")
        XCTAssertEqual(try Data(contentsOf: paths.gitconfig), before["gitconfig"]!)
    }

    func testFailureAtCommitLeavesShellsOnThePreviousGeneration() async throws {
        let engine = engine()
        _ = try await engine.switchProfile(work.id, in: config)
        let before = snapshotFiles()

        try FileManager.default.removeItem(at: paths.generation)
        try FileManager.default.createDirectory(at: paths.generation, withIntermediateDirectories: true)

        let error = await switchError { try await engine.switchProfile(self.personal.id, in: self.config) }
        guard case .stepFailed(.state, _, .complete) = error else { return XCTFail("\(String(describing: error))") }
        XCTAssertEqual(try Data(contentsOf: paths.state), before["state.json"]!)
        XCTAssertEqual(try Data(contentsOf: paths.envSh), before["env.sh"]!)
        XCTAssertEqual(system.ghActive, "rafael-npu")
        XCTAssertNil(system.launchdClaude)
    }

    func testRollbackThatFailsIsReportedAsIncomplete() async throws {
        let engine = engine()
        _ = try await engine.switchProfile(work.id, in: config)   // launchd unset

        // Switch to personal: setenv succeeds, env files fail, and undoing
        // launchd (unsetenv) fails too.
        system.failLaunchctlUnset = true
        try FileManager.default.removeItem(at: paths.envFish)
        try FileManager.default.createDirectory(at: paths.envFish, withIntermediateDirectories: true)

        let error = await switchError { try await engine.switchProfile(self.personal.id, in: self.config) }
        guard case let .stepFailed(step, _, rollback) = error else { return XCTFail("\(String(describing: error))") }
        XCTAssertEqual(step, .envFiles)
        XCTAssertEqual(rollback, .incomplete(failed: [.launchd]))
        XCTAssertEqual(system.ghActive, "rafael-npu", "the other steps were still undone")
    }

    func testConcurrentSwitchIsRejectedAsBusy() async throws {
        let engine = engine()
        system.ghSwitchDelay = 0.4
        let (personalID, workID, config) = (personal.id, work.id, config!)
        let first = Task { try await engine.switchProfile(personalID, in: config) }
        try await Task.sleep(for: .milliseconds(100))
        let second = await switchError { try await engine.switchProfile(workID, in: config) }
        XCTAssertEqual(second, .busy)
        let firstResult = try await first.value
        XCTAssertEqual(firstResult.state.profileId, personalID)
    }
}
