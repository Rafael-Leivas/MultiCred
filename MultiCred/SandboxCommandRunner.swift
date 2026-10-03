import Foundation
import MultiCredCore

/// Command runner for the app's test mode: a small simulated world, so the UI
/// behaves like the real thing without touching the real system.
///
/// - gh: two fake accounts; `auth switch` changes the active one; `auth login` is
///   handled by the login simulator, not here.
/// - launchctl: remembers `CLAUDE_CONFIG_DIR` in memory only.
/// - git: read-only commands (`--version`, `config --get…`) really run, with
///   HOME pointing at the sandbox and the system config disabled, so Verify sees
///   what the sandbox files say. Any git command that could write is refused.
/// - claude: version only; status falls back to the sandbox state files.
/// Every request is also recorded and logged.
actor SandboxCommandRunner: CommandRunner {
    struct Entry: Sendable {
        let date: Date
        let command: String
    }

    private let sandboxHome: URL
    private let realRunner = ProcessRunner()
    private(set) var entries: [Entry] = []
    private var ghActive = "conta-trabalho"
    private var ghLogins = ["conta-trabalho", "conta-pessoal"]
    private var launchdClaude: String?

    init(sandboxHome: URL) {
        self.sandboxHome = sandboxHome
    }

    func run(_ request: CommandRequest) async throws -> CommandResult {
        entries.append(Entry(date: Date(), command: request.displayString))
        let args = request.arguments
        switch request.executable.lastPathComponent {
        case "gh": return gh(args)
        case "launchctl": return launchctl(args)
        case "git": return try await git(request)
        case "claude":
            return args == ["--version"] ? ok("2.1.288 (Claude Code) [simulado]\n") : CommandResult(exitCode: 1)
        default:
            // Login shells, security, anything else: nothing runs.
            return CommandResult(exitCode: 0)
        }
    }

    /// Adds a login created by the GitHub login simulator.
    func addGitHubLogin(_ login: String) {
        if !ghLogins.contains(login) { ghLogins.append(login) }
        ghActive = login
    }

    private func gh(_ args: [String]) -> CommandResult {
        if args.starts(with: ["--version"]) { return ok("gh version 2.101.0 (simulado)\n") }
        if args.starts(with: ["auth", "status", "--json"]) {
            let entries = ghLogins.map {
                #"{"host":"github.com","login":"\#($0)","active":\#($0 == ghActive),"state":"success","tokenSource":"keyring","gitProtocol":"https"}"#
            }
            return ok(#"{"hosts":{"github.com":[\#(entries.joined(separator: ","))]}}"#)
        }
        if args.starts(with: ["config", "get", "-h"]) { return ok(ghActive + "\n") }
        if args.starts(with: ["auth", "switch"]), let user = args.last {
            guard ghLogins.contains(where: { $0.caseInsensitiveCompare(user) == .orderedSame }) else {
                return CommandResult(exitCode: 1, standardError: Data("not logged in to github.com account \(user)\n".utf8))
            }
            ghActive = user
            return ok("")
        }
        return CommandResult(exitCode: 0)
    }

    private func launchctl(_ args: [String]) -> CommandResult {
        switch args.first {
        case "getenv": return ok(launchdClaude.map { $0 + "\n" } ?? "")
        case "setenv" where args.count == 3: launchdClaude = args[2]
        case "unsetenv": launchdClaude = nil
        default: break
        }
        return ok("")
    }

    private func git(_ request: CommandRequest) async throws -> CommandResult {
        let args = request.arguments
        let readOnly = args == ["--version"] || (args.first == "config" && args.contains("--get"))
        guard readOnly else { return CommandResult(exitCode: 0) }
        var env = request.environment
        env["HOME"] = sandboxHome.path
        env["GIT_CONFIG_NOSYSTEM"] = "1"
        env["GIT_CONFIG_GLOBAL"] = nil
        var sandboxed = request
        sandboxed.environment = env
        sandboxed.currentDirectory = sandboxHome
        return try await realRunner.run(sandboxed)
    }

    private func ok(_ text: String) -> CommandResult {
        CommandResult(exitCode: 0, standardOutput: Data(text.utf8))
    }
}
