import Foundation

/// The `claude mcp add` commands that connect the help server to Claude Code.
///
/// MultiCred never edits Claude's configuration; it only shows these commands
/// for the user to run. `claude mcp add` writes to the config of the active
/// `CLAUDE_CONFIG_DIR`, so there is one command per Claude folder.
public enum ClaudeHelpConnection {
    public static let serverName = "multicred"

    public struct Target: Equatable, Sendable, Identifiable {
        /// nil = the default `~/.claude` folder (no `CLAUDE_CONFIG_DIR`).
        public let configDir: String?
        public let label: String
        public let command: String
        public let removeCommand: String
        public var id: String { configDir ?? "default" }
    }

    public static func targets(config: Config, executable: URL, environment: SystemEnvironment) -> [Target] {
        // Equivalent spellings of a folder (trailing slash, `..`) are one target, and
        // `~/.claude` is the default folder, which has no CLAUDE_CONFIG_DIR.
        let defaultFolder = ClaudePaths.standardize(environment.home.appendingPathComponent(".claude").path)
        var dirs = Set<String>()
        let configured = config.profiles.compactMap(\.claudeConfigDir) + config.claudeAccounts.compactMap(\.configDir)
        for dir in configured.map(ClaudePaths.standardize) where dir != defaultFolder { dirs.insert(dir) }
        let ordered: [String?] = [nil] + dirs.sorted()
        let program = ShellQuoting.quoteForDisplay(executable.path)
        return ordered.map { dir in
            let prefix = dir.map { "CLAUDE_CONFIG_DIR=\(ShellQuoting.quoteForDisplay($0)) " } ?? ""
            return Target(
                configDir: dir,
                label: dir.map(environment.abbreviate) ?? "Conta padrão (~/.claude)",
                command: "\(prefix)claude mcp add --scope user \(serverName) -- \(program)",
                removeCommand: "\(prefix)claude mcp remove \(serverName) --scope user"
            )
        }
    }

    /// `claude mcp add` registers the helper's path. If the app runs from a
    /// temporary or movable place that path breaks later; says so (nil = fine).
    public static func locationWarning(executable: URL, environment: SystemEnvironment) -> String? {
        let path = executable.standardizedFileURL.path
        let stable = ["/Applications/", environment.home.path + "/Applications/"]
        if stable.contains(where: path.hasPrefix) { return nil }
        if path.contains("/AppTranslocation/") {
            return "O macOS abriu o MultiCred de uma pasta temporária (App Translocation). Mova o app para Aplicativos, abra de novo e só então copie o comando; senão a conexão quebra."
        }
        return "O MultiCred está em \(environment.abbreviate(path.components(separatedBy: ".app/").first.map { $0 + ".app" } ?? path)). O comando registra esse caminho: mova o app para Aplicativos antes de conectar, ou a conexão quebra quando ele mudar de lugar."
    }
}
