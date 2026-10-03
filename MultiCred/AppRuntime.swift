import Foundation
import MultiCredCore

/// How "Entrar no Claude" runs.
enum ClaudeLoginMode: Equatable {
    /// Test mode default: a shell script that imitates the CLI. Touches nothing.
    case simulated
    /// Test mode with `-MultiCredRealClaudeLogin YES`: the real `claude auth login`
    /// for accounts whose folder is inside the sandbox home. Opens the browser and
    /// creates one Claude Code keychain item for that folder; everything else stays
    /// simulated. The default account is refused: it shares the keychain item
    /// "Claude Code-credentials" with the user's real ~/.claude account.
    case realInSandbox
    /// The real system.
    case real
}

/// Chooses which system the app talks to.
///
/// Debug builds start in test mode: a sandbox home in the temporary directory,
/// a simulated world for gh/launchctl (see `SandboxCommandRunner`) and an
/// in-memory keychain. The real system is used only when launched with
/// `-MultiCredRealSystem YES` (scheme "MultiCred (sistema real)").
/// Release builds always use the real system.
enum AppRuntime {
    static let realSystemArgument = "MultiCredRealSystem"
    static let realClaudeLoginArgument = "MultiCredRealClaudeLogin"

    struct Runtime {
        let environment: SystemEnvironment
        let sandboxRunner: SandboxCommandRunner?
    }

    static func make() -> Runtime {
        #if DEBUG
        if launchArgumentIsYes(realSystemArgument) {
            return Runtime(environment: RealEnvironment.make(), sandboxRunner: nil)
        }
        let sandbox = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("multicred-sandbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        let runner = SandboxCommandRunner(sandboxHome: sandbox.resolvingSymlinksInPath())
        let base = RealEnvironment.makeDryRun(sandboxHome: sandbox.resolvingSymlinksInPath())
        let environment = SystemEnvironment(
            mode: .dryRun,
            home: base.home,
            loginShell: base.loginShell,
            userName: base.userName,
            runner: runner,
            keychain: base.keychain
        )
        return Runtime(environment: environment, sandboxRunner: runner)
        #else
        return Runtime(environment: RealEnvironment.make(), sandboxRunner: nil)
        #endif
    }

    static func claudeLoginMode(for environment: SystemEnvironment) -> ClaudeLoginMode {
        if environment.mode == .real { return .real }
        #if DEBUG
        if launchArgumentIsYes(realClaudeLoginArgument) { return .realInSandbox }
        #endif
        return .simulated
    }

    /// Where tools may be installed, using the real home: in test mode `~`
    /// points at the sandbox, where nothing is installed.
    static var realToolDirectories: [String] {
        let realHome = RealEnvironment.realHomeDirectory.path
        return ["/opt/homebrew/bin", "/usr/local/bin", "\(realHome)/.local/bin", "/usr/bin", "/bin"]
    }

    private static func launchArgumentIsYes(_ name: String) -> Bool {
        let arguments = ProcessInfo.processInfo.arguments
        let yes: Set<String> = ["YES", "yes", "1", "true"]
        // Also accept "-Name YES" as a single argument.
        if arguments.contains(where: { argument in
            let parts = argument.split(separator: " ")
            return parts.count == 2 && parts[0] == "-" + name && yes.contains(String(parts[1]))
        }) {
            return true
        }
        guard let index = arguments.firstIndex(of: "-" + name), index + 1 < arguments.count else { return false }
        return yes.contains(arguments[index + 1])
    }
}
