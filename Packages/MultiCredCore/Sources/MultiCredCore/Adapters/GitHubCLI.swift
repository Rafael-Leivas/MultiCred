import Foundation

public struct GitHubLogin: Hashable, Sendable, Decodable {
    public let host: String
    public let login: String
    public let active: Bool
    /// "success" when the stored token works; anything else means "log in again".
    public let state: String

    public var isUsable: Bool { state == "success" }
}

public enum GitHubCLIError: Error, Equatable {
    case unexpectedOutput(String)
}

/// Thin wrapper over `gh`. Never asks for tokens: `gh auth status --json hosts`
/// carries no token unless `--show-token` is passed, which this type never does.
public struct GitHubCLI: Sendable {
    let runner: any CommandRunner
    let executable: URL
    let environment: [String: String]

    public init(runner: any CommandRunner, executable: URL, baseEnvironment: [String: String]) {
        self.runner = runner
        self.executable = executable
        var env = baseEnvironment
        env["GH_PROMPT_DISABLED"] = "1"
        env["GH_NO_UPDATE_NOTIFIER"] = "1"
        env["NO_COLOR"] = "1"
        self.environment = env
    }

    /// Every account gh knows, on every host.
    public func logins() async throws -> [GitHubLogin] {
        let result = try await runner.runChecked(request(["auth", "status", "--json", "hosts"]))
        struct Response: Decodable { let hosts: [String: [GitHubLogin]] }
        do {
            let response = try JSONDecoder().decode(Response.self, from: result.standardOutput)
            return response.hosts.values.flatMap { $0 }.sorted { ($0.host, $0.login) < ($1.host, $1.login) }
        } catch {
            throw GitHubCLIError.unexpectedOutput(String(result.stdout.prefix(200)))
        }
    }

    public func activeLogin(host: String) async throws -> String? {
        try await logins().first { $0.host == host && $0.active }?.login
    }

    public func switchAccount(host: String, user: String) async throws {
        try await runner.runChecked(request(["auth", "switch", "--hostname", host, "--user", user]))
    }

    func request(_ arguments: [String]) -> CommandRequest {
        CommandRequest(executable: executable, arguments: arguments, environment: environment, timeout: .seconds(20))
    }
}
