import Foundation
import XCTest
@testable import MultiCredCore

/// Scripted fake runner. Records every request; answers from the first matching rule.
final class FakeCommandRunner: CommandRunner, @unchecked Sendable {
    struct Rule {
        let matches: @Sendable (CommandRequest) -> Bool
        let respond: @Sendable (CommandRequest) throws -> CommandResult
    }

    private let lock = NSLock()
    private var rules: [Rule] = []
    private var recorded: [CommandRequest] = []

    var requests: [CommandRequest] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    /// Answers requests whose executable name is `tool` and whose arguments start with `prefix`.
    func on(_ tool: String, _ prefix: [String] = [], respond: @escaping @Sendable (CommandRequest) throws -> CommandResult) {
        lock.lock(); defer { lock.unlock() }
        rules.append(Rule(
            matches: { $0.executable.lastPathComponent == tool && $0.arguments.starts(with: prefix) },
            respond: respond
        ))
    }

    func on(_ tool: String, _ prefix: [String] = [], stdout: String = "", exitCode: Int32 = 0) {
        on(tool, prefix) { _ in CommandResult(exitCode: exitCode, standardOutput: Data(stdout.utf8)) }
    }

    func run(_ request: CommandRequest) async throws -> CommandResult {
        let rule = lock.withLock {
            recorded.append(request)
            return rules.first { $0.matches(request) }
        }
        guard let rule else {
            throw CommandError.launchFailed(executable: request.executable.lastPathComponent, reason: "no fake rule for \(request.displayString)")
        }
        return try rule.respond(request)
    }
}

/// Base class: every test gets a fresh temporary HOME and fake collaborators.
/// It fails loudly if anything points at the real home directory.
class SafeTestCase: XCTestCase {
    private(set) var home: URL!
    private(set) var runner: FakeCommandRunner!
    private(set) var keychain: InMemoryKeychainStore!
    private(set) var claudeStore: InMemoryClaudeCredentialStore!
    private(set) var environment: SystemEnvironment!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("MultiCredTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        // Resolve /var -> /private/var so path comparisons are stable.
        home = base.resolvingSymlinksInPath()

        let realHome = RealEnvironment.realHomeDirectory.resolvingSymlinksInPath().path
        precondition(home.path != realHome && !realHome.hasPrefix(home.path + "/"), "Test HOME must never be the real home")

        runner = FakeCommandRunner()
        keychain = InMemoryKeychainStore()
        claudeStore = InMemoryClaudeCredentialStore()
        environment = SystemEnvironment(
            mode: .test,
            home: home,
            loginShell: "/bin/zsh",
            userName: "tester",
            runner: runner,
            keychain: keychain,
            claudeCredentials: claudeStore,
            clock: { Date(timeIntervalSince1970: 1_790_000_000) }
        )
    }

    override func tearDownWithError() throws {
        if let home { try? FileManager.default.removeItem(at: home) }
        try super.tearDownWithError()
    }

    @discardableResult
    func makeExecutable(_ relativePath: String) throws -> URL {
        let url = home.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    func read(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    func mode(of url: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) ?? -1
    }
}
