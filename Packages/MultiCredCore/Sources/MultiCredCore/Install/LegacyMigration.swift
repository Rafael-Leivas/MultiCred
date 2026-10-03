import Foundation

/// The shell-script version MultiCred replaces (`~/Perfis`: trocar-perfil.sh,
/// claude-env.sh, instalar.sh, perfis.conf). Its rc line and git include would
/// fight with MultiCred's, so onboarding offers to remove them, and its
/// perfis.conf becomes suggested profiles. Nothing is ever executed or sourced.
public enum LegacyMigration {
    public struct Finding: Equatable, Sendable {
        public let file: URL
        public let lines: [String]
    }

    public struct LegacyProfile: Equatable, Sendable {
        public var key: String
        public var gitName: String?
        public var gitEmail: String?
        public var githubUser: String?
        public var sshKey: String?
        /// nil = default Claude account (~/.claude).
        public var claudeDir: String?

        public var displayName: String {
            key.prefix(1).uppercased() + key.dropFirst().lowercased()
        }
    }

    public static func folder(environment: SystemEnvironment) -> URL {
        environment.home.appendingPathComponent("Perfis", isDirectory: true)
    }

    static func isLegacyRCLine(_ line: String) -> Bool {
        line.contains("Perfis/claude-env.sh")
    }

    static func isLegacyIncludePath(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("path") && trimmed.contains("Perfis/git-atual.gitconfig")
    }

    /// Lines from the legacy install still present in rc files and git config.
    public static func findings(environment: SystemEnvironment) -> [Finding] {
        Integrations.allBlockFiles(environment: environment).compactMap { file in
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
            let lines = text.components(separatedBy: "\n").filter { isLegacyRCLine($0) || isLegacyIncludePath($0) }
            return lines.isEmpty ? nil : Finding(file: file, lines: lines)
        }
    }

    /// Removes the legacy rc line (and the comment instalar.sh put above it) and
    /// the legacy `[include]` section. Everything else stays byte for byte.
    public static func removeLegacyLines(from text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        var index = 0
        while index < lines.count {
            let line = lines[index]
            if isLegacyRCLine(line) {
                lines.remove(at: index)
                if index > 0, lines[index - 1].trimmingCharacters(in: .whitespaces).hasPrefix("# Perfis") {
                    lines.remove(at: index - 1)
                    index -= 1
                }
                removeBlankBefore(&lines, &index)
                continue
            }
            if isLegacyIncludePath(line) {
                lines.remove(at: index)
                let headerIndex = index - 1
                let sectionNowEmpty = index >= lines.count || lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("[")
                    || lines[index].trimmingCharacters(in: .whitespaces).isEmpty
                if headerIndex >= 0, lines[headerIndex].trimmingCharacters(in: .whitespaces).lowercased() == "[include]", sectionNowEmpty {
                    lines.remove(at: headerIndex)
                    index = headerIndex
                    removeBlankBefore(&lines, &index)
                }
                continue
            }
            index += 1
        }
        return lines.joined(separator: "\n")
    }

    private static func removeBlankBefore(_ lines: inout [String], _ index: inout Int) {
        if index > 0, index - 1 < lines.count, lines[index - 1].trimmingCharacters(in: .whitespaces).isEmpty {
            lines.remove(at: index - 1)
            index -= 1
        }
    }

    /// Profiles from `~/Perfis/perfis.conf`, in file order.
    public static func importProfiles(environment: SystemEnvironment) -> [LegacyProfile] {
        let conf = folder(environment: environment).appendingPathComponent("perfis.conf")
        guard let text = try? String(contentsOf: conf, encoding: .utf8) else { return [] }
        return profiles(fromConf: text, environment: environment)
    }

    /// The legacy active profile (`~/Perfis/atual`), lowercased key.
    public static func activeProfileKey(environment: SystemEnvironment) -> String? {
        let file = folder(environment: environment).appendingPathComponent("atual")
        return (try? String(contentsOf: file, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    static func profiles(fromConf text: String, environment: SystemEnvironment) -> [LegacyProfile] {
        let values = parseConf(text)
        let suffixes = ["_GIT_NOME", "_GIT_EMAIL", "_GH_USUARIO", "_SSH_CHAVE", "_CLAUDE_DIR"]
        var order: [String] = []
        for (key, _) in values {
            guard let suffix = suffixes.first(where: key.hasSuffix) else { continue }
            let prefix = String(key.dropLast(suffix.count))
            if !prefix.isEmpty, !order.contains(prefix) { order.append(prefix) }
        }
        return order.map { prefix in
            func value(_ suffix: String) -> String? {
                values.last { $0.0 == prefix + suffix }.map { expand($0.1, environment: environment) }.flatMap { $0.isEmpty ? nil : $0 }
            }
            var claudeDir = value("_CLAUDE_DIR")
            if let dir = claudeDir {
                claudeDir = (try? ClaudePaths.canonicalConfigDir(dir, environment: environment)) ?? nil
            }
            return LegacyProfile(
                key: prefix,
                gitName: value("_GIT_NOME"),
                gitEmail: value("_GIT_EMAIL"),
                githubUser: value("_GH_USUARIO"),
                sshKey: value("_SSH_CHAVE"),
                claudeDir: claudeDir
            )
        }
    }

    /// `KEY="value"` / `KEY='value'` / `KEY=value` lines; comments and anything
    /// else are ignored. Values are never evaluated.
    static func parseConf(_ text: String) -> [(String, String)] {
        text.components(separatedBy: "\n").compactMap { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), let equals = line.firstIndex(of: "=") else { return nil }
            let key = String(line[..<equals])
            guard key.range(of: "^[A-Z_][A-Z0-9_]*$", options: .regularExpression) != nil else { return nil }
            var rest = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if let quote = rest.first, quote == "\"" || quote == "'" {
                rest.removeFirst()
                guard let close = rest.firstIndex(of: quote) else { return nil }
                return (key, String(rest[..<close]))
            }
            if let comment = rest.firstIndex(of: "#") { rest = String(rest[..<comment]) }
            return (key, rest.trimmingCharacters(in: .whitespaces))
        }
    }

    static func expand(_ value: String, environment: SystemEnvironment) -> String {
        let home = environment.home.path
        return environment.expandTilde(
            value.replacingOccurrences(of: "${HOME}", with: home).replacingOccurrences(of: "$HOME", with: home)
        )
    }
}
