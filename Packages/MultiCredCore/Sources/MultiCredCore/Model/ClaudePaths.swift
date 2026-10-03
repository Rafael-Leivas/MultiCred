import CryptoKit
import Foundation

/// Rules for Claude Code config directories, from the Phase 1 spike
/// (docs/spikes/claude-config-dir.md):
///
/// - Default mode (no `CLAUDE_CONFIG_DIR`) uses `~/.claude` plus `~/.claude.json`
///   and the keychain item `Claude Code-credentials`.
/// - With the variable set, the keychain item is
///   `Claude Code-credentials-` + first 8 hex chars of sha256(path text).
///   The hash is over the exact text, so `/x` and `/x/` are different accounts.
///
/// MultiCred therefore always stores and exports one canonical form: absolute,
/// standardized, no trailing slash, no `~`.
public enum ClaudePaths {
    public enum PathError: Error, Equatable {
        case empty
        case notAbsolute(String)
        case controlCharacters
    }

    /// Canonical directory for `input`, or nil when it is the default `~/.claude`
    /// (which must be used with `CLAUDE_CONFIG_DIR` unset, never set to it).
    public static func canonicalConfigDir(_ input: String, environment: SystemEnvironment) throws -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw PathError.empty }
        guard !Validation.hasControlCharacters(trimmed) else { throw PathError.controlCharacters }
        let expanded = environment.expandTilde(trimmed)
        guard expanded.hasPrefix("/") else { throw PathError.notAbsolute(input) }
        let canonical = standardize(expanded)
        return canonical == defaultConfigDir(environment: environment) ? nil : canonical
    }

    public static func defaultConfigDir(environment: SystemEnvironment) -> String {
        standardize(environment.home.path + "/.claude")
    }

    /// The directory an account actually uses on disk.
    public static func effectiveDirectory(of account: ClaudeAccount, environment: SystemEnvironment) -> String {
        account.configDir ?? defaultConfigDir(environment: environment)
    }

    /// Name of the keychain item Claude Code uses for this account. Used only to
    /// check whether an item exists, through attributes; never to read it.
    public static func keychainService(forConfigDir configDir: String?) -> String {
        guard let configDir else { return "Claude Code-credentials" }
        let digest = SHA256.hash(data: Data(configDir.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "Claude Code-credentials-" + hex.prefix(8)
    }

    /// Suggested folder for a new account: `~/.claude-<slug>`.
    public static func suggestedConfigDir(nickname: String, environment: SystemEnvironment) -> String {
        let slug = nickname
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
            .map { $0.isLetter || $0.isNumber ? String($0) : "-" }
            .joined()
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return standardize(environment.home.path + "/.claude-" + (slug.isEmpty ? "conta" : slug))
    }

    static func standardize(_ path: String) -> String {
        var standardized = URL(fileURLWithPath: path).standardized.path
        while standardized.count > 1, standardized.hasSuffix("/") {
            standardized.removeLast()
        }
        return standardized
    }
}
