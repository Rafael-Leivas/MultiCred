import Foundation

/// What a Claude Code config folder contains, so the user can tell folders
/// apart ("which one is my work account?"). Read locally and never sent anywhere.
/// Only metadata is read: the login e-mail from `.claude.json` and, per
/// conversation, its title, project folder and date. No tokens, no message bodies.
public struct ClaudeFolderSummary: Equatable, Sendable {
    public struct Conversation: Equatable, Sendable {
        public let title: String
        /// Project folder the conversation ran in (`cwd`), abbreviated.
        public let project: String?
        public let lastActivity: Date
    }

    /// nil = default `~/.claude`.
    public let configDir: String?
    public let path: String
    public let email: String?
    public let organization: String?
    public let projectCount: Int
    public let conversationCount: Int
    public let lastActivity: Date?
    public let recentConversations: [Conversation]

    public var exists: Bool { FileManager.default.fileExists(atPath: path) }
}

/// Claude Code layout (observed with 2.1.x): `<folder>/projects/<project>/<session>.jsonl`,
/// one JSON object per line. Titles come from `custom-title`, then `ai-title`,
/// then `last-prompt` lines.
public enum ClaudeFolderInspector {
    public static func summarize(configDir: String?, environment: SystemEnvironment, limit: Int = 8) -> ClaudeFolderSummary {
        let path = configDir ?? ClaudePaths.defaultConfigDir(environment: environment)
        let account = ClaudeAccount(nickname: "", color: .graphite, configDir: configDir)
        let (email, organization) = loginIdentity(stateFile: ClaudeAccountFiles.stateFile(for: account, environment: environment))

        let projects = URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent("projects", isDirectory: true)
        let fm = FileManager.default
        let projectFolders = ((try? fm.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }

        var sessions: [(URL, Date)] = []
        for folder in projectFolders {
            let files = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for file in files where file.pathExtension == "jsonl" {
                let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                sessions.append((file, date))
            }
        }
        sessions.sort { $0.1 > $1.1 }

        let recent = sessions.prefix(limit).map { file, date in
            let info = conversationInfo(file)
            return ClaudeFolderSummary.Conversation(
                title: info.title ?? "(sem título)",
                project: info.cwd.map(environment.abbreviate),
                lastActivity: date
            )
        }
        return ClaudeFolderSummary(
            configDir: configDir,
            path: path,
            email: email,
            organization: organization,
            projectCount: projectFolders.count,
            conversationCount: sessions.count,
            lastActivity: sessions.first?.1,
            recentConversations: Array(recent)
        )
    }

    /// `~/.claude` and every `~/.claude-*` folder.
    public static func discoverFolders(environment: SystemEnvironment) -> [String?] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: environment.home.path)) ?? []
        return names
            .filter { $0 == ".claude" || $0.hasPrefix(".claude-") }
            .sorted()
            .compactMap { name -> String?? in
                let url = environment.home.appendingPathComponent(name, isDirectory: true)
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
                return .some(name == ".claude" ? nil : ClaudePaths.standardize(url.path))
            }
    }

    static func loginIdentity(stateFile: URL) -> (String?, String?) {
        guard let data = try? Data(contentsOf: stateFile),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = object["oauthAccount"] as? [String: Any]
        else { return (nil, nil) }
        return (oauth["emailAddress"] as? String, oauth["organizationName"] as? String)
    }

    /// Title and project of one session file. Only the few metadata line types
    /// are decoded; message lines are skipped without parsing.
    static func conversationInfo(_ file: URL) -> (title: String?, cwd: String?) {
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return (nil, nil) }
        var custom: String?
        var aiTitle: String?
        var lastPrompt: String?
        var cwd: String?
        for line in data.split(separator: UInt8(ascii: "\n")) {
            let isTitle = line.range(of: Data(#""custom-title""#.utf8)) != nil
                || line.range(of: Data(#""ai-title""#.utf8)) != nil
                || line.range(of: Data(#""last-prompt""#.utf8)) != nil
            let needsCwd = cwd == nil && line.range(of: Data(#""cwd""#.utf8)) != nil
            guard isTitle || needsCwd,
                  let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
            else { continue }
            switch object["type"] as? String {
            case "custom-title": custom = (object["customTitle"] as? String) ?? custom
            case "ai-title": aiTitle = (object["aiTitle"] as? String) ?? aiTitle
            case "last-prompt": lastPrompt = (object["lastPrompt"] as? String) ?? lastPrompt
            default: break
            }
            if cwd == nil { cwd = object["cwd"] as? String }
        }
        let title = [custom, aiTitle, lastPrompt.map(shorten)]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        return (title, cwd)
    }

    private static func shorten(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return flat.count > 80 ? String(flat.prefix(80)) + "…" : flat
    }
}
