import Foundation

/// Thrown when something tries to leave the read-only boundary.
public struct ReadOnlyViolation: Error, CustomStringConvertible, Equatable {
    public let what: String
    public init(_ what: String) { self.what = what }
    public var description: String { "Read-only mode: \(what) is not allowed" }
}

/// Lets only a fixed list of read-only commands through to `inner`; everything
/// else throws `ReadOnlyViolation` before any process starts. The help MCP
/// server runs on top of this so it cannot change the Mac even by mistake.
public struct ReadOnlyCommandRunner: CommandRunner {
    private let inner: any CommandRunner
    private let loginShell: String

    public init(inner: any CommandRunner, loginShell: String) {
        self.inner = inner
        self.loginShell = loginShell
    }

    public func run(_ request: CommandRequest) async throws -> CommandResult {
        guard Self.isAllowed(request, loginShell: loginShell) else {
            throw ReadOnlyViolation(request.displayString)
        }
        return try await inner.run(request)
    }

    /// Exact command shapes only (never prefixes or deny-lists): anything the app
    /// does not use for diagnostics is refused.
    static func isAllowed(_ request: CommandRequest, loginShell: String) -> Bool {
        let tool = request.executable.lastPathComponent
        let args = request.arguments
        if args == ["--version"] { return ["git", "gh", "claude"].contains(tool) }
        switch tool {
        case "git":
            if args.count == 5, args[0] == "config", args[1] == "--global", args[2] == "--includes", args[3] == "--get" { return isName(args[4]) }
            if args.count == 5, args[0] == "config", args[1] == "--includes", args[2] == "--show-origin", args[3] == "--get" { return isName(args[4]) }
            return false
        case "gh":
            if args == ["auth", "status", "--json", "hosts"] { return true }
            return args.count == 5 && args[0] == "config" && args[1] == "get" && args[2] == "-h" && isName(args[3]) && args[4] == "user"
        case "claude":
            return args == ["auth", "status"] || args == ["auth", "status", "--json"] || args == ["auth", "status", "--text"]
        case "launchctl":
            return args.count == 2 && args[0] == "getenv" && isName(args[1])
        default:
            // The login shell is asked only for its PATH (see `ToolLocator`).
            return request.executable.path == loginShell && args == ["-l", "-i", "-c", ToolLocator.pathProbeScript]
        }
    }

    private static func isName(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0) }
    }
}
