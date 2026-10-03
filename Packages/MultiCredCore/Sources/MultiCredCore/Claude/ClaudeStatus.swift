import Foundation

/// Whether a Claude Code account is logged in. Derived without ever reading a
/// token: from `claude auth status --json`, or from the non-secret
/// `oauthAccount` entry of the account's `.claude.json`.
public enum ClaudeLoginStatus: Equatable, Sendable {
    case loggedIn(email: String?)
    case loggedOut
    /// Could not tell (CLI missing, unexpected output); never shown as "logged out".
    case unknown(String)

    public var isLoggedIn: Bool {
        if case .loggedIn = self { return true }
        return false
    }
}

public enum ClaudeAccountFiles {
    /// `.claude.json` for the account: `~/.claude.json` in default mode,
    /// `<dir>/.claude.json` when `CLAUDE_CONFIG_DIR` is set (spike, item d).
    public static func stateFile(for account: ClaudeAccount, environment: SystemEnvironment) -> URL {
        if let dir = account.configDir {
            return URL(fileURLWithPath: dir, isDirectory: true).appendingPathComponent(".claude.json")
        }
        return environment.home.appendingPathComponent(".claude.json")
    }

    /// Reads only `oauthAccount.emailAddress`. nil when the file is missing or
    /// unreadable; `.loggedOut` when it exists without `oauthAccount`.
    public static func statusFromStateFile(for account: ClaudeAccount, environment: SystemEnvironment) -> ClaudeLoginStatus? {
        guard let data = try? Data(contentsOf: stateFile(for: account, environment: environment)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        guard let oauth = object["oauthAccount"] as? [String: Any] else { return .loggedOut }
        return .loggedIn(email: oauth["emailAddress"] as? String)
    }
}

/// Wrapper over the `claude` binary for status and logout. Login runs in a
/// pseudo-terminal owned by the app (see `LoginOutputParser`).
public struct ClaudeCLI: Sendable {
    let runner: any CommandRunner
    let executable: URL
    let baseEnvironment: [String: String]

    public init(runner: any CommandRunner, executable: URL, baseEnvironment: [String: String]) {
        self.runner = runner
        self.executable = executable
        self.baseEnvironment = baseEnvironment
    }

    /// Process environment for an account: `CLAUDE_CONFIG_DIR` set to its
    /// canonical directory, or absent for the default account.
    public static func environment(for account: ClaudeAccount, base: [String: String]) -> [String: String] {
        var env = base
        env["CLAUDE_CONFIG_DIR"] = account.configDir
        env["NO_COLOR"] = "1"
        return env
    }

    public func authStatus(for account: ClaudeAccount) async -> ClaudeLoginStatus {
        let request = CommandRequest(
            executable: executable,
            arguments: ["auth", "status", "--json"],
            environment: Self.environment(for: account, base: baseEnvironment),
            timeout: .seconds(20)
        )
        do {
            let result = try await runner.run(request)
            if let parsed = Self.parseStatus(result.standardOutput) { return parsed }
            return .unknown("unexpected output (exit \(result.exitCode))")
        } catch {
            return .unknown(String(describing: error))
        }
    }

    /// Logs the account out through Claude Code itself, which removes only that
    /// directory's keychain item (spike, item d).
    public func logout(_ account: ClaudeAccount) async throws {
        try await runner.runChecked(CommandRequest(
            executable: executable,
            arguments: ["auth", "logout"],
            environment: Self.environment(for: account, base: baseEnvironment),
            timeout: .seconds(20)
        ))
    }

    /// The JSON format of `claude auth status` was not observed in the spike, so
    /// parsing is tolerant: a boolean login flag under a few likely names, and an
    /// e-mail at the top level or inside an account object. Returns nil when the
    /// output says nothing recognizable, so callers fall back to the state file.
    static func parseStatus(_ data: Data) -> ClaudeLoginStatus? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let flagKeys = ["loggedIn", "logged_in", "isLoggedIn", "authenticated", "isAuthenticated"]
        let flag = flagKeys.lazy.compactMap { object[$0] as? Bool }.first
        let email = findEmail(in: object)
        switch flag {
        case true?: return .loggedIn(email: email)
        case false?: return .loggedOut
        case nil: return email.map { .loggedIn(email: $0) }
        }
    }

    private static func findEmail(in object: [String: Any]) -> String? {
        for key in ["email", "emailAddress"] {
            if let value = object[key] as? String, value.contains("@") { return value }
        }
        for key in ["account", "oauthAccount", "user"] {
            if let nested = object[key] as? [String: Any], let email = findEmail(in: nested) { return email }
        }
        return nil
    }
}

/// Caches statuses so menus never wait for `claude` (node startup is ~1 s).
public actor ClaudeStatusService {
    private let environment: SystemEnvironment
    private let tools: any ToolLocating
    private let ttl: TimeInterval
    private var cache: [UUID: (status: ClaudeLoginStatus, at: Date)] = [:]

    public init(environment: SystemEnvironment, tools: any ToolLocating, ttl: TimeInterval = 300) {
        self.environment = environment
        self.tools = tools
        self.ttl = ttl
    }

    public func cached(_ accountId: UUID) -> ClaudeLoginStatus? {
        cache[accountId]?.status
    }

    public func invalidate(_ accountId: UUID? = nil) {
        if let accountId { cache[accountId] = nil } else { cache.removeAll() }
    }

    public func status(for account: ClaudeAccount, force: Bool = false) async -> ClaudeLoginStatus {
        if !force, let entry = cache[account.id], environment.clock().timeIntervalSince(entry.at) < ttl {
            return entry.status
        }
        let status = await resolve(account)
        cache[account.id] = (status, environment.clock())
        return status
    }

    private func resolve(_ account: ClaudeAccount) async -> ClaudeLoginStatus {
        let fromFile = ClaudeAccountFiles.statusFromStateFile(for: account, environment: environment)
        guard let claude = await tools.locate(.claude) else {
            return fromFile ?? .unknown("Claude Code not found")
        }
        let cli = ClaudeCLI(
            runner: environment.runner,
            executable: claude,
            baseEnvironment: environment.baseProcessEnvironment(path: await tools.searchDirectories())
        )
        switch await cli.authStatus(for: account) {
        case let .loggedIn(email):
            if email == nil, case let .loggedIn(fileEmail)? = fromFile { return .loggedIn(email: fileEmail) }
            return .loggedIn(email: email)
        case .loggedOut:
            return .loggedOut
        case let .unknown(reason):
            return fromFile ?? .unknown(reason)
        }
    }
}
