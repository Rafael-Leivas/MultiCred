import Foundation

/// Everything MultiCred needs from the machine, injected.
///
/// No type in MultiCredCore reads the real home directory, the process
/// environment or spawns processes on its own; they all receive this value.
/// Tests build it with a temporary home, a fake runner and an in-memory keychain
/// (see `ArchitectureGuardTests`).
public struct SystemEnvironment: Sendable {
    public enum Mode: String, Sendable {
        /// Touches the real system.
        case real
        /// App test mode: sandbox home, commands only recorded.
        case dryRun
        /// Unit tests.
        case test
    }

    public let mode: Mode
    public let home: URL
    /// The user's login shell, e.g. `/bin/zsh`.
    public let loginShell: String
    public let userName: String
    public let runner: any CommandRunner
    public let keychain: any KeychainStore
    public let clock: @Sendable () -> Date

    public init(
        mode: Mode,
        home: URL,
        loginShell: String,
        userName: String,
        runner: any CommandRunner,
        keychain: any KeychainStore,
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.mode = mode
        self.home = home.standardizedFileURL
        self.loginShell = loginShell
        self.userName = userName
        self.runner = runner
        self.keychain = keychain
        self.clock = clock
    }

    /// `~/Library/Application Support/MultiCred`
    public var appSupportDirectory: URL {
        home.appendingPathComponent("Library/Application Support/MultiCred", isDirectory: true)
    }

    /// `~/Library/Logs/MultiCred`
    public var logsDirectory: URL {
        home.appendingPathComponent("Library/Logs/MultiCred", isDirectory: true)
    }

    /// Expands a leading `~` or `~/` against the injected home. Other paths are returned as is.
    public func expandTilde(_ path: String) -> String {
        if path == "~" { return home.path }
        if path.hasPrefix("~/") { return home.path + "/" + path.dropFirst(2) }
        return path
    }

    /// Shortens a path under home to `~/…` for display.
    public func abbreviate(_ path: String) -> String {
        let homePath = home.path
        if path == homePath { return "~" }
        if path.hasPrefix(homePath + "/") { return "~/" + path.dropFirst(homePath.count + 1) }
        return path
    }

    /// Minimal, explicit environment for child processes. Never the app's own.
    public func baseProcessEnvironment(path: [String]) -> [String: String] {
        [
            "HOME": home.path,
            "USER": userName,
            "LOGNAME": userName,
            "SHELL": loginShell,
            "PATH": path.joined(separator: ":"),
            "LANG": "en_US.UTF-8",
        ]
    }
}
