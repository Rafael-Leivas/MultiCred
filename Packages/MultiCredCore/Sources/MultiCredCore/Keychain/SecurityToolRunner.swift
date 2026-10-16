import Foundation

/// Runs `/usr/bin/security` synchronously (Keychain APIs are synchronous).
/// The injected runner works off the calling thread, so waiting cannot deadlock.
struct SecurityToolRunner: Sendable {
    let toolPath: String
    let runner: any CommandRunner

    func run(_ arguments: [String], standardInput: Data? = nil) throws -> CommandResult {
        let request = CommandRequest(
            executable: URL(fileURLWithPath: toolPath),
            arguments: arguments,
            environment: ["PATH": "/usr/bin:/bin"],
            standardInput: standardInput,
            timeout: .seconds(15)
        )
        let box = ResultBox()
        let semaphore = DispatchSemaphore(value: 0)
        let runner = self.runner
        Task.detached {
            do { box.set(.success(try await runner.run(request))) } catch { box.set(.failure(error)) }
            semaphore.signal()
        }
        semaphore.wait()
        return try box.get()
    }

    /// One `security -i` line. Values are double-quoted (service names contain
    /// spaces); callers only pass names MultiCred builds, never user text.
    static func interactiveLine(_ words: [String]) -> String {
        words.map { word in
            word.contains(where: { $0 == " " }) ? "\"\(word)\"" : word
        }.joined(separator: " ") + "\n"
    }

    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}

private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<CommandResult, any Error> = .failure(KeychainError.toolFailed("no result"))
    func set(_ value: Result<CommandResult, any Error>) { lock.withLock { result = value } }
    func get() throws -> CommandResult { try lock.withLock { try result.get() } }
}

/// Real `ClaudeCredentialStore`: Claude Code's folder items and MultiCred's
/// login vault, both through `security` (no password prompts: items created by
/// `security` are readable by it, as Claude Code's own are).
public struct SecurityClaudeCredentialStore: ClaudeCredentialStore {
    public static let vaultService = "app.multicred.claude-login"

    private let tool: SecurityToolRunner
    private let userName: String

    public init(userName: String, runner: any CommandRunner = ProcessRunner(), toolPath: String = "/usr/bin/security") {
        tool = SecurityToolRunner(toolPath: toolPath, runner: runner)
        self.userName = userName
    }

    public func readFolderItem(configDir: String?) throws -> Data? {
        try read(service: ClaudePaths.keychainService(forConfigDir: configDir), account: userName)
    }

    public func writeFolderItem(configDir: String?, data: Data) throws {
        try write(service: ClaudePaths.keychainService(forConfigDir: configDir), account: userName, data: data)
    }

    public func deleteFolderItem(configDir: String?) throws {
        try delete(service: ClaudePaths.keychainService(forConfigDir: configDir), account: userName)
    }

    public func readVault(_ key: String) throws -> Data? {
        try read(service: Self.vaultService, account: key)
    }

    public func writeVault(_ key: String, data: Data) throws {
        try write(service: Self.vaultService, account: key, data: data)
    }

    public func deleteVault(_ key: String) throws {
        try delete(service: Self.vaultService, account: key)
    }

    private func read(service: String, account: String) throws -> Data? {
        let result = try tool.run(["find-generic-password", "-s", service, "-a", account, "-w"])
        if result.exitCode == 44 { return nil }  // errSecItemNotFound
        guard result.exitCode == 0 else { throw ClaudeLoginError.securityFailed(Self.stderr(result)) }
        var data = result.standardOutput
        while data.last == 0x0A { data.removeLast() }
        return data
    }

    private func write(service: String, account: String, data: Data) throws {
        let line = SecurityToolRunner.interactiveLine(["add-generic-password", "-U", "-s", service, "-a", account, "-X", SecurityToolRunner.hex(data)])
        let result = try tool.run(["-i"], standardInput: Data(line.utf8))
        guard result.exitCode == 0, result.standardError.isEmpty else { throw ClaudeLoginError.securityFailed(Self.stderr(result)) }
    }

    private func delete(service: String, account: String) throws {
        let result = try tool.run(["delete-generic-password", "-s", service, "-a", account])
        guard result.exitCode == 0 || result.exitCode == 44 else { throw ClaudeLoginError.securityFailed(Self.stderr(result)) }
    }

    private static func stderr(_ result: CommandResult) -> String {
        String(decoding: result.standardError, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
