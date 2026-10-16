import Foundation

/// The only place in MultiCredCore allowed to look at the real user account.
/// `ArchitectureGuardTests` fails if these APIs show up anywhere else.
public enum RealEnvironment {
    /// The real system. The app only uses this when started with
    /// `-MultiCredRealSystem YES` (Debug) or in Release builds.
    public static func make() -> SystemEnvironment {
        let account = currentAccount()
        return SystemEnvironment(
            mode: .real,
            home: account.home,
            loginShell: account.shell,
            userName: account.name,
            runner: ProcessRunner(),
            keychain: SecItemKeychainStore(),
            claudeCredentials: SecurityClaudeCredentialStore(userName: account.name)
        )
    }

    /// App test mode: a sandbox home, commands recorded but not executed,
    /// in-memory keychain. Safe to run on a developer machine.
    public static func makeDryRun(sandboxHome: URL, runner: DryRunCommandRunner = DryRunCommandRunner()) -> SystemEnvironment {
        let account = currentAccount()
        try? FileManager.default.createDirectory(at: sandboxHome, withIntermediateDirectories: true)
        return SystemEnvironment(
            mode: .dryRun,
            home: sandboxHome,
            loginShell: account.shell,
            userName: account.name,
            runner: runner,
            keychain: InMemoryKeychainStore()
        )
    }

    /// The real home directory, used by test code to assert it never gets used.
    public static var realHomeDirectory: URL { currentAccount().home }

    private static func currentAccount() -> (name: String, home: URL, shell: String) {
        guard let entry = getpwuid(getuid()) else {
            return (NSUserName(), URL(fileURLWithPath: NSHomeDirectory()), "/bin/zsh")
        }
        let name = String(cString: entry.pointee.pw_name)
        let home = URL(fileURLWithPath: String(cString: entry.pointee.pw_dir), isDirectory: true)
        let shell = String(cString: entry.pointee.pw_shell)
        return (name, home, shell.isEmpty ? "/bin/zsh" : shell)
    }
}
