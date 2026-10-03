import Foundation

/// External tools MultiCred coordinates.
public enum Tool: String, CaseIterable, Sendable {
    case git
    case gh
    case claude

    public var displayName: String {
        switch self {
        case .git: "git"
        case .gh: "GitHub CLI"
        case .claude: "Claude Code"
        }
    }
}

/// Finds tool binaries for a GUI app, which does not inherit the shell's PATH.
///
/// Search order (first match wins):
/// 1. Well-known install locations: Homebrew (Apple Silicon and Intel),
///    `~/.local/bin` (Claude Code native installer), `/usr/bin`, `/bin`.
/// 2. Entries from the user's login shell PATH (npm globals, asdf, mise, ...).
///
/// Well-known locations come first on purpose: a login-shell PATH entry should
/// not be able to shadow `/opt/homebrew/bin/gh` with something else named `gh`.
public actor ToolLocator {
    public static let defaultSearchDirectories = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "~/.local/bin",
        "/usr/bin",
        "/bin",
    ]

    static let pathMarker = "__MULTICRED_PATH__"

    private let environment: SystemEnvironment
    private let wellKnownDirectories: [String]
    private let loginShellTimeout: Duration
    private var loginShellPATH: [String]?

    public init(
        environment: SystemEnvironment,
        wellKnownDirectories: [String] = ToolLocator.defaultSearchDirectories,
        loginShellTimeout: Duration = .seconds(5)
    ) {
        self.environment = environment
        self.wellKnownDirectories = wellKnownDirectories
        self.loginShellTimeout = loginShellTimeout
    }

    /// Forgets the cached login shell PATH (for "Check again").
    public func invalidate() {
        loginShellPATH = nil
    }

    /// The ordered, de-duplicated directories searched for tools. Also used as
    /// PATH for child processes, so tools that call other tools find them.
    public func searchDirectories() async -> [String] {
        let fixed = wellKnownDirectories.map(environment.expandTilde)
        let fromShell = await userLoginShellPATH()
        var seen = Set<String>()
        return (fixed + fromShell).filter { seen.insert($0).inserted }
    }

    /// Absolute path of the tool, or nil when it is not installed.
    public func locate(_ tool: Tool) async -> URL? {
        for directory in await searchDirectories() {
            let candidate = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent(tool.rawValue)
            if Self.isExecutableFile(candidate) { return candidate }
        }
        return nil
    }

    /// First line of `<tool> --version`, or nil when the tool is missing or fails.
    public func version(of tool: Tool) async -> String? {
        guard let url = await locate(tool) else { return nil }
        let request = CommandRequest(
            executable: url,
            arguments: ["--version"],
            environment: environment.baseProcessEnvironment(path: await searchDirectories()),
            timeout: .seconds(10)
        )
        guard let result = try? await environment.runner.run(request), result.succeeded else { return nil }
        return result.stdout.split(whereSeparator: \.isNewline).first.map(String.init)
    }

    /// PATH as seen by the user's login shell. Empty when the shell fails or hangs;
    /// the well-known directories still work in that case.
    public func userLoginShellPATH() async -> [String] {
        if let loginShellPATH { return loginShellPATH }
        let request = CommandRequest(
            executable: URL(fileURLWithPath: environment.loginShell),
            arguments: ["-l", "-c", "printf '\(Self.pathMarker)%s\(Self.pathMarker)' \"$PATH\""],
            environment: [
                "HOME": environment.home.path,
                "USER": environment.userName,
                "LOGNAME": environment.userName,
                "SHELL": environment.loginShell,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "TERM": "dumb",
            ],
            timeout: loginShellTimeout
        )
        let entries: [String]
        if let result = try? await environment.runner.run(request), result.succeeded {
            entries = Self.parseLoginShellOutput(result.stdout)
        } else {
            entries = []
        }
        loginShellPATH = entries
        return entries
    }

    /// Extracts PATH between markers; rc files may print banners around it.
    /// Only absolute entries are kept.
    static func parseLoginShellOutput(_ output: String) -> [String] {
        let parts = output.components(separatedBy: pathMarker)
        guard parts.count >= 3 else { return [] }
        return parts[1]
            .split(separator: ":", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { $0.hasPrefix("/") }
    }

    static func isExecutableFile(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let fm = FileManager.default
        return fm.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
            && fm.isExecutableFile(atPath: url.path)
    }
}
