import MultiCredCore
import SwiftUI

/// Login e-mail, counts and recent conversations of a Claude Code folder, so
/// folders can be told apart. Everything is read locally.
struct ClaudeFolderPreview: View {
    let summary: ClaudeFolderSummary
    var maxConversations = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 16) {
                fact("Conta", summary.email.map { email in summary.organization.map { "\(email) · \($0)" } ?? email } ?? "sem login")
                fact("Projetos", "\(summary.projectCount)")
                fact("Conversas", "\(summary.conversationCount)")
                fact("Última atividade", summary.lastActivity.map { $0.formatted(.relative(presentation: .named)) } ?? "nunca")
            }
            if summary.recentConversations.isEmpty {
                Text("Nenhuma conversa nesta pasta.").foregroundStyle(.secondary).font(.callout)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(summary.recentConversations.prefix(maxConversations).enumerated()), id: \.offset) { index, conversation in
                        if index > 0 { Divider() }
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(conversation.title).lineLimit(1)
                                if let project = conversation.project {
                                    Text(project).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            Spacer()
                            Text(conversation.lastActivity.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 6)
                    }
                }
                .padding(.horizontal, 10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
            }
            Text("Lido só neste Mac: e-mail do login e título, projeto e data de cada conversa.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private func fact(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout.weight(.medium)).lineLimit(1)
        }
    }
}

/// Loads summaries off the main thread (session files can be large).
@MainActor
@Observable
final class ClaudeFolderSummaries {
    private(set) var byPath: [String: ClaudeFolderSummary] = [:]
    private(set) var discovered: [String?] = []

    func load(configDirs: [String?], environment: SystemEnvironment) async {
        let results = await Task.detached(priority: .userInitiated) {
            configDirs.map { ClaudeFolderInspector.summarize(configDir: $0, environment: environment) }
        }.value
        for summary in results { byPath[summary.path] = summary }
    }

    func discover(environment: SystemEnvironment) async {
        discovered = await Task.detached { ClaudeFolderInspector.discoverFolders(environment: environment) }.value
        await load(configDirs: discovered, environment: environment)
    }

    func summary(for configDir: String?, environment: SystemEnvironment) -> ClaudeFolderSummary? {
        byPath[configDir ?? ClaudePaths.defaultConfigDir(environment: environment)]
    }
}
