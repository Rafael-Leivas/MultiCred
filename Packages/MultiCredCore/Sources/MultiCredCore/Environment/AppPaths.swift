import Foundation

/// Every file MultiCred owns, derived from the injected home (docs/PLAN.md §4.2).
public struct AppPaths: Sendable {
    public let root: URL

    public init(environment: SystemEnvironment) {
        root = environment.appSupportDirectory
    }

    public var config: URL { root.appendingPathComponent("config.json") }
    public var state: URL { root.appendingPathComponent("state.json") }
    /// A single integer; shell hooks re-source the env file when it changes.
    public var generation: URL { root.appendingPathComponent("generation") }
    public var gitconfig: URL { root.appendingPathComponent("gitconfig") }
    public var envSh: URL { root.appendingPathComponent("env.sh") }
    public var envFish: URL { root.appendingPathComponent("env.fish") }
    public var shellDirectory: URL { root.appendingPathComponent("shell", isDirectory: true) }
    public var backups: URL { root.appendingPathComponent("backups", isDirectory: true) }
    public var manifest: URL { root.appendingPathComponent("manifest.json") }

    public func hook(_ shell: ShellKind) -> URL {
        shellDirectory.appendingPathComponent("hook.\(shell.rawValue)")
    }
}
