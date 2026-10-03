import Foundation

/// The only text MultiCred adds to files it does not own (rc files, the global
/// git config) lives between these markers, so it can be found, replaced and
/// removed without touching anything else in the file.
public enum ManagedBlock {
    public static let begin = "# >>> MultiCred >>>"
    public static let end = "# <<< MultiCred <<<"

    public enum BlockError: Error, Equatable {
        /// A begin marker without an end marker (edited by hand).
        case unterminated
    }

    public static func contains(_ text: String) -> Bool {
        text.split(separator: "\n", omittingEmptySubsequences: false).contains { $0.trimmingCharacters(in: .whitespaces) == begin }
    }

    /// The block's inner lines, if present.
    public static func body(in text: String) -> String? {
        let lines = text.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == begin }),
              let stop = lines[start...].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == end })
        else { return nil }
        return lines[(start + 1)..<stop].joined(separator: "\n")
    }

    /// Removes every block (and the blank line placed before it on insertion).
    public static func remove(from text: String) throws -> String {
        var lines = text.components(separatedBy: "\n")
        while let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == begin }) {
            guard let stop = lines[start...].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == end }) else {
                throw BlockError.unterminated
            }
            lines.removeSubrange(start...stop)
            if start > 0, start - 1 < lines.count, lines[start - 1].trimmingCharacters(in: .whitespaces).isEmpty {
                lines.remove(at: start - 1)
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Removes any existing block and appends a fresh one at the end. Running it
    /// twice gives the same text (idempotent).
    public static func appendAtEnd(_ body: String, to text: String) throws -> String {
        var base = try remove(from: text)
        while base.hasSuffix("\n\n") { base.removeLast() }
        if !base.isEmpty, !base.hasSuffix("\n") { base += "\n" }
        let separator = base.isEmpty ? "" : "\n"
        return base + separator + begin + "\n" + body + "\n" + end + "\n"
    }

    /// True when the block exists and only blank lines or comments follow it.
    public static func isLast(in text: String) -> Bool {
        let lines = text.components(separatedBy: "\n")
        guard let stop = lines.lastIndex(where: { $0.trimmingCharacters(in: .whitespaces) == end }) else { return false }
        return lines[(stop + 1)...].allSatisfy {
            let trimmed = $0.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix(";")
        }
    }
}

/// Where MultiCred hooks into shells and git, for one user.
public enum Integrations {
    static let supportPathInHome = "Library/Application Support/MultiCred"

    /// rc files that source the hook. bash needs both: Terminal opens login
    /// shells (`.bash_profile`), other terminals run interactive non-login shells
    /// (`.bashrc`). The hook guards against double registration.
    public static func rcFiles(for shell: ShellKind, environment: SystemEnvironment) -> [URL] {
        switch shell {
        case .zsh: [environment.home.appendingPathComponent(".zshrc")]
        case .bash: [environment.home.appendingPathComponent(".bash_profile"), environment.home.appendingPathComponent(".bashrc")]
        case .fish: []
        }
    }

    /// fish loads every file in conf.d; MultiCred owns this one entirely.
    public static func fishConfFile(environment: SystemEnvironment) -> URL {
        environment.home.appendingPathComponent(".config/fish/conf.d/multicred.fish")
    }

    public static func rcBlock(for shell: ShellKind) -> String {
        let hook = "$HOME/\(supportPathInHome)/shell/hook.\(shell.rawValue)"
        switch shell {
        case .zsh: return "[ -f \"\(hook)\" ] && source \"\(hook)\""
        case .bash: return "[ -f \"\(hook)\" ] && . \"\(hook)\""
        case .fish: return "test -f \"\(hook)\"; and source \"\(hook)\""
        }
    }

    public static func fishConfContents() -> String {
        "\(ManagedBlock.begin)\n# Created by MultiCred; removed on uninstall.\n\(rcBlock(for: .fish))\n\(ManagedBlock.end)\n"
    }

    /// The global git config git itself would use: `~/.gitconfig` when it exists,
    /// else `~/.config/git/config` when that exists, else a new `~/.gitconfig`.
    public static func globalGitConfig(environment: SystemEnvironment) -> URL {
        let primary = environment.home.appendingPathComponent(".gitconfig")
        let xdg = environment.home.appendingPathComponent(".config/git/config")
        var info = stat()
        if lstat(primary.path, &info) == 0 { return primary }
        if FileManager.default.fileExists(atPath: xdg.path) { return xdg }
        return primary
    }

    public static let gitIncludeBlock = "[include]\n\tpath = \"~/\(supportPathInHome)/gitconfig\""

    /// Every file that may contain a MultiCred block, installed or not.
    public static func allBlockFiles(environment: SystemEnvironment) -> [URL] {
        ShellKind.allCases.flatMap { rcFiles(for: $0, environment: environment) } + [globalGitConfig(environment: environment)]
    }
}
