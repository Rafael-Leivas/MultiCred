import Foundation

/// The only place that changes the launchd user environment. Values set here
/// reach GUI apps opened afterwards; they do not survive a reboot, which is why
/// the app re-applies the active profile at login.
public struct Launchctl: Sendable {
    public static let executable = URL(fileURLWithPath: "/bin/launchctl")

    let runner: any CommandRunner
    let environment: [String: String]

    public init(runner: any CommandRunner, baseEnvironment: [String: String]) {
        self.runner = runner
        self.environment = baseEnvironment
    }

    /// nil when the variable is not set.
    public func getenv(_ name: String) async throws -> String? {
        let result = try await runner.runChecked(request(["getenv", name]))
        let value = result.stdout.trimmingCharacters(in: .newlines)
        return value.isEmpty ? nil : value
    }

    public func setenv(_ name: String, _ value: String) async throws {
        try await runner.runChecked(request(["setenv", name, value]))
    }

    public func unsetenv(_ name: String) async throws {
        try await runner.runChecked(request(["unsetenv", name]))
    }

    /// Sets the value, or unsets it for nil.
    public func apply(_ name: String, _ value: String?) async throws {
        if let value { try await setenv(name, value) } else { try await unsetenv(name) }
    }

    private func request(_ arguments: [String]) -> CommandRequest {
        CommandRequest(executable: Self.executable, arguments: arguments, environment: environment, timeout: .seconds(10))
    }
}
