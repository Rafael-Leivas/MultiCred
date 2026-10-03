import Foundation

/// A single external command invocation.
///
/// There is deliberately no shell involved: the executable is an absolute path and
/// arguments are passed as an array, so user-provided text can never be parsed as
/// shell syntax. The environment is explicit and never inherited from the app.
public struct CommandRequest: Sendable, Equatable {
    public var executable: URL
    public var arguments: [String]
    public var environment: [String: String]
    public var standardInput: Data?
    public var currentDirectory: URL?
    public var timeout: Duration

    public init(
        executable: URL,
        arguments: [String] = [],
        environment: [String: String] = [:],
        standardInput: Data? = nil,
        currentDirectory: URL? = nil,
        timeout: Duration = .seconds(15)
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.standardInput = standardInput
        self.currentDirectory = currentDirectory
        self.timeout = timeout
    }

    /// Human-readable form for logs and the "command that would run" previews.
    /// Never include `standardInput` here: it may carry a secret.
    public var displayString: String {
        ([executable.path] + arguments).map(ShellQuoting.quoteForDisplay).joined(separator: " ")
    }
}

public struct CommandResult: Sendable, Equatable {
    public var exitCode: Int32
    public var standardOutput: Data
    public var standardError: Data

    public init(exitCode: Int32, standardOutput: Data = Data(), standardError: Data = Data()) {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
    }

    public var stdout: String { String(decoding: standardOutput, as: UTF8.self) }
    public var stderr: String { String(decoding: standardError, as: UTF8.self) }
    public var succeeded: Bool { exitCode == 0 }
}

public enum CommandError: Error, Equatable, CustomStringConvertible {
    case launchFailed(executable: String, reason: String)
    case timedOut(executable: String, seconds: Double)
    case nonZeroExit(executable: String, code: Int32, stderr: String)

    public var description: String {
        switch self {
        case let .launchFailed(executable, reason):
            "Could not start \(executable): \(reason)"
        case let .timedOut(executable, seconds):
            "\(executable) did not finish within \(seconds)s"
        case let .nonZeroExit(executable, code, stderr):
            "\(executable) exited with code \(code): \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
    }
}

/// Runs external commands. Every piece of code that touches git, gh, claude,
/// launchctl or security goes through this protocol so tests can substitute a fake.
public protocol CommandRunner: Sendable {
    func run(_ request: CommandRequest) async throws -> CommandResult
}

extension CommandRunner {
    /// Runs the command and throws `CommandError.nonZeroExit` when it fails.
    @discardableResult
    public func runChecked(_ request: CommandRequest) async throws -> CommandResult {
        let result = try await run(request)
        guard result.succeeded else {
            throw CommandError.nonZeroExit(
                executable: request.executable.lastPathComponent,
                code: result.exitCode,
                stderr: result.stderr
            )
        }
        return result
    }
}

extension Duration {
    var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}
