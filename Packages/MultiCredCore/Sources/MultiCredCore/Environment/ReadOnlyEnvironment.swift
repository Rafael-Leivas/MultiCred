import Foundation

public extension SystemEnvironment {
    /// The same machine seen through read-only guards: only allow-listed
    /// commands run, the Keychain answers presence only, Claude credentials
    /// cannot be read or changed. Used by the help MCP server.
    func readOnly() -> SystemEnvironment {
        SystemEnvironment(
            mode: mode,
            home: home,
            loginShell: loginShell,
            userName: userName,
            runner: ReadOnlyCommandRunner(inner: runner, loginShell: loginShell),
            keychain: PresenceOnlyKeychain(inner: keychain),
            claudeCredentials: PresenceOnlyClaudeCredentialStore(inner: claudeCredentials),
            clock: clock
        )
    }
}
