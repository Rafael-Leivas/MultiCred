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
        runner.on("gh", ["auth", "switch"]) { [self] request in
            let user = request.arguments.last!
            if ghSwitchDelay > 0 { Thread.sleep(forTimeInterval: ghSwitchDelay) }
            return locked {
                if user == failGHSwitchTo { return CommandResult(exitCode: 1, standardError: Data("gh: keyring locked".utf8)) }
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
        let ghPersonal = GitHubAccount(nickname: "Pessoal", username: "RafaelBLeivas", color: .orange) // case differs from gh on purpose
        let claudeWork = ClaudeAccount(nickname: "NPU", color: .indigo, configDir: nil)
        let claudePersonal = ClaudeAccount(nickname: "Pessoal", color: .orange, configDir: claudePersonalDir)
        let openAI = APIKeyAccount(nickname: "NPU", provider: .openai, color: .indigo)
        let gemini = APIKeyAccount(nickname: "Pessoal", provider: .gemini, color: .orange)
        try keychain.setSecret(Data("sk".utf8), account: openAI.keychainAccount)
        try keychain.setSecret(Data("g".utf8), account: gemini.keychainAccount)

        work = Profile(name: "Trabalho NPU", color: .indigo, gitIdentityId: gitWork.id, githubAccountId: ghWork.id, claudeAccountId: claudeWork.id, apiKeyIds: [openAI.id])
        personal = Profile(name: "Pessoal", color: .orange, gitIdentityId: gitPersonal.id, githubAccountId: ghPersonal.id, claudeAccountId: claudePersonal.id, apiKeyIds: [gemini.id])
        config = Config(
            gitIdentities: [gitWork, gitPersonal],
            githubAccounts: [ghWork, ghPersonal],
            claudeAccounts: [claudeWork, claudePersonal],
            apiKeys: [openAI, gemini],
            profiles: [work, personal]
        )
    }

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

        XCTAssertEqual(result.appliedSteps, [.git, .github, .launchd, .envFiles, .state])
        XCTAssertEqual(system.ghActive, "rafaelbleivas", "uses gh's own spelling of the login")
        XCTAssertEqual(system.launchdClaude, claudePersonalDir)

        let gitconfig = try read(paths.gitconfig)
        XCTAssertTrue(gitconfig.contains("email = \"r@gmail.com\""))
        XCTAssertTrue(gitconfig.contains("sshCommand = \"ssh -i '\(home.path)/.ssh/id_pessoal' -o IdentitiesOnly=yes\""))

        let envSh = try read(paths.envSh)
        XCTAssertTrue(envSh.contains("unset GEMINI_API_KEY OPENAI_API_KEY"))
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

    func testProfileWithoutGitHubOrClaudeTouchesNeither() async throws {
        var bare = Profile(name: "Só git", color: .green, gitIdentityId: config.gitIdentities[0].id)
        bare.apiKeyIds = []
        config.profiles.append(bare)
        let result = try await engine().switchProfile(bare.id, in: config)
        XCTAssertEqual(result.appliedSteps, [.git, .envFiles, .state])
        XCTAssertEqual(mutatingCommands(), [])
        XCTAssertFalse(try read(paths.envSh).contains("CLAUDE_CONFIG_DIR"))
    }

    func testProfileWithoutClaudeKeepsTheLastAppliedAccount() async throws {
        _ = try await engine().switchProfile(personal.id, in: config)
        let bare = Profile(name: "Sem Claude", color: .green, gitIdentityId: config.gitIdentities[0].id)
        config.profiles.append(bare)
        let result = try await engine().switchProfile(bare.id, in: config)
        XCTAssertEqual(result.claudeTarget, .directory(claudePersonalDir))
        XCTAssertEqual(system.launchdClaude, claudePersonalDir)
    }

    func testClaudeOnlySwitchKeepsGitAndGitHubAndClearsOnNextProfileSwitch() async throws {
        let engine = engine()
        _ = try await engine.switchProfile(work.id, in: config)
        let gitBefore = try read(paths.gitconfig)
        let commandsBefore = runner.requests.count

        let result = try await engine.switchClaudeOnly(to: config.claudeAccounts[1].id, in: config)
        XCTAssertEqual(result.appliedSteps, [.launchd, .envFiles, .state])
        XCTAssertEqual(result.state.profileId, work.id)
        XCTAssertEqual(result.state.claudeOverrideId, config.claudeAccounts[1].id)
        XCTAssertEqual(system.launchdClaude, claudePersonalDir)
        XCTAssertEqual(try read(paths.gitconfig), gitBefore)
        XCTAssertFalse(runner.requests.dropFirst(commandsBefore).contains { $0.executable.lastPathComponent == "gh" })
        XCTAssertTrue(try read(paths.envSh).contains("OPENAI_API_KEY=\"$("), "API keys still follow the profile")

        let reapplied = try await engine.reapplyActiveProfile(in: config)
        XCTAssertEqual(reapplied?.state.claudeOverrideId, config.claudeAccounts[1].id, "reapply at login keeps the override")
        XCTAssertEqual(system.launchdClaude, claudePersonalDir)

        let next = try await engine.switchProfile(work.id, in: config)
        XCTAssertNil(next.state.claudeOverrideId)
        XCTAssertNil(system.launchdClaude)
    }

    func testGenerationIncreasesAndActivatedAtOnlyChangesOnProfileSwitch() async throws {
        let engine = engine()
        let first = try await engine.switchProfile(work.id, in: config)
        let second = try await engine.switchClaudeOnly(to: config.claudeAccounts[1].id, in: config)
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
        system.ghLogins = [("rafael-npu", "success"), ("rafaelbleivas", "failure")]
        var error = await switchError { try await self.engine().switchProfile(self.personal.id, in: self.config) }
        XCTAssertEqual(error, .preflight(.githubAccountNotLoggedIn(host: "github.com", user: "RafaelBLeivas")))

        system.ghLogins = [("rafael-npu", "success"), ("rafaelbleivas", "success")]
        try FileManager.default.removeItem(atPath: claudePersonalDir)
        error = await switchError { try await self.engine().switchProfile(self.personal.id, in: self.config) }
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
