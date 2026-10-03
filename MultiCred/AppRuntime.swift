import Foundation
import MultiCredCore

/// Chooses which system the app talks to.
///
/// Debug builds start in test mode: a sandbox home in the temporary directory,
/// commands recorded instead of executed, and an in-memory keychain. The real
/// system is used only when launched with `-MultiCredRealSystem YES`.
/// Release builds always use the real system.
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

enum AppRuntime {
    static let realSystemArgument = "MultiCredRealSystem"
    static let realClaudeLoginArgument = "MultiCredRealClaudeLogin"

    static func claudeLoginMode(for environment: SystemEnvironment) -> ClaudeLoginMode {
        if environment.mode == .real { return .real }
        #if DEBUG
        if launchArgumentIsYes(realClaudeLoginArgument) { return .realInSandbox }
        #endif
        return .simulated
    }

    /// Where the real Claude Code may be installed, using the real home: in test
    /// mode `~` points at the sandbox, where Claude Code is not installed.
    static var realClaudeSearchDirectories: [String] {
        let realHome = RealEnvironment.realHomeDirectory.path
        return ["\(realHome)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
    }

    static func makeEnvironment() -> SystemEnvironment {
        #if DEBUG
        // Launch arguments only, never persisted defaults: a forgotten
        // `defaults write` must not silently switch a debug build to the real system.
        if launchArgumentIsYes(realSystemArgument) {
            return RealEnvironment.make()
        }
        let sandbox = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("multicred-sandbox", isDirectory: true)
        return RealEnvironment.makeDryRun(sandboxHome: sandbox)
        #else
        return RealEnvironment.make()
        #endif
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
