import Foundation

/// The user guide embedded in the binary (`Guide/guia.md`, the single source).
///
/// Layout: `## Sobre` (free text), `## Tarefas` and `## Problemas`, whose
/// entries are `### id · Title` followed by a `palavras-chave:` / `sintomas:`
/// line and the body.
public struct Guide: Sendable {
    public struct Entry: Sendable, Equatable {
        public let id: String
        public let title: String
        public let keywords: [String]
        public let body: String
    }

    public let version: String
    public let about: String
    public let tasks: [Entry]
    public let problems: [Entry]

    public static let bundled = Guide(markdown: String(decoding: PackageResources.guia_md, as: UTF8.self))

    public init(markdown: String) {
        var version = "?"
        var sections: [String: [String]] = [:]
        var current: String?
        var inFence = false
        for line in markdown.components(separatedBy: "\n") {
            if line.hasPrefix("```") { inFence.toggle() }
            if inFence || line.hasPrefix("```") {
                if let current { sections[current, default: []].append(line) }
            } else if line.hasPrefix("versão:") {
                version = line.dropFirst("versão:".count).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("## ") {
                current = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                sections[current!] = []
            } else if let current {
                sections[current, default: []].append(line)
            }
        }
        self.version = version
        about = (sections["Sobre"] ?? []).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        tasks = Self.entries(in: sections["Tarefas"] ?? [])
        problems = Self.entries(in: sections["Problemas"] ?? [])
    }

    private static func entries(in lines: [String]) -> [Entry] {
        var result: [Entry] = []
        var header: (id: String, title: String)?
        var keywords: [String] = []
        var body: [String] = []
        func flush() {
            guard let header else { return }
            result.append(Entry(
                id: header.id, title: header.title, keywords: keywords,
                body: body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            ))
        }
        var inFence = false
        for line in lines {
            if line.hasPrefix("```") { inFence.toggle(); body.append(line); continue }
            if inFence { body.append(line); continue }
            if line.hasPrefix("### ") {
                flush()
                let parts = line.dropFirst(4).components(separatedBy: " · ")
                header = (parts[0].trimmingCharacters(in: .whitespaces), parts.dropFirst().joined(separator: " · "))
                keywords = []
                body = []
            } else if line.hasPrefix("palavras-chave:") || line.hasPrefix("sintomas:") {
                keywords += line.drop { $0 != ":" }.dropFirst().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            } else {
                body.append(line)
            }
        }
        flush()
        return result
    }
}
