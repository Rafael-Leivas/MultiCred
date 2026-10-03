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

/// Account detail page: what this folder holds, plus the account actions.
struct ClaudeAccountDetailPage: View {
    let model: AppModel
    let navigator: MainNavigator
    let accountId: UUID

    @State private var summaries = ClaudeFolderSummaries()
    @State private var confirmLogout = false
    @State private var confirmRemoval = false

    var body: some View {
        if let account = model.config.claudeAccount(accountId) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    AccountAvatar(name: account.nickname, color: account.color, size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.nickname).font(.title2.weight(.semibold))
                        Text(account.configDir.map(model.environment.abbreviate) ?? "~/.claude (padrão)")
                            .font(.callout.monospaced()).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let status = model.claudeStatus(account) {
                        StatusPill(text: status.pill.0, tone: status.pill.1)
                    }
                }
                let used = model.profilesUsing(claudeAccount: account.id).map(\.name)
                Text(used.isEmpty ? "Nenhum perfil usa esta conta." : "Usada nos perfis: \(used.joined(separator: ", ")).")
                    .foregroundStyle(.secondary)

                if let summary = summaries.summary(for: account.configDir, environment: model.environment) {
                    ClaudeFolderPreview(summary: summary)
                } else {
                    ProgressView("Lendo a pasta…")
                }
                Spacer(minLength: 0)
                HStack {
                    Button("Remover conta…", role: .destructive) { confirmRemoval = true }.foregroundStyle(.red)
                    Button("Sair da conta…") { confirmLogout = true }
                    Spacer()
                    Button("Usar só esta conta Claude agora") {
                        Task { if let error = await model.switchClaudeOnly(to: account.id) { model.lastError = error } }
                    }
                    .disabled(model.state.appliedClaudeAccountId == account.id || model.isSwitching)
                    Button("Entrar…") { navigator.showClaudeLogin(account) }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
            .navigationTitle(account.nickname)
            .task {
                await summaries.load(configDirs: [account.configDir], environment: model.environment)
                await model.refreshClaudeStatus(account.id, force: false)
            }
            .confirmationDialog(logoutTitle(account), isPresented: $confirmLogout) {
                Button("Sair da conta", role: account.isDefault ? .destructive : nil) {
                    Task {
                        if let error = await model.logoutClaudeAccount(account.id) { model.lastError = error }
                        await summaries.load(configDirs: [account.configDir], environment: model.environment)
                    }
                }
            } message: {
                Text(logoutMessage(account))
            }
            .confirmationDialog("Remover a conta \(account.nickname)?", isPresented: $confirmRemoval) {
                Button("Remover", role: .destructive) {
                    model.removeClaudeAccount(account.id)
                    navigator.back()
                }
            } message: {
                Text("A pasta, as conversas e o login continuam no seu Mac; só sai da lista do MultiCred. Perfis que a usam deixam de trocar o Claude.")
            }
        } else {
            ContentUnavailableView("Conta removida", systemImage: "xmark.circle")
        }
    }
}

func logoutTitle(_ account: ClaudeAccount) -> String {
    account.isDefault ? "Sair da sua conta principal do Claude Code (~/.claude)?" : "Sair da conta \(account.nickname)?"
}

func logoutMessage(_ account: ClaudeAccount) -> String {
    if account.isDefault {
        return "~/.claude é a pasta padrão: é a conta que o Claude Code usa quando nenhum perfil aponta outra pasta. O Claude Code vai apagar esse login e será preciso entrar de novo. As conversas não são apagadas."
    }
    return "O Claude Code apaga o login desta pasta (\(account.configDir ?? "")). As conversas ficam; para usar a conta de novo, entre outra vez."
}
