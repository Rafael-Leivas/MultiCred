import MultiCredCore
import SwiftUI

/// The single main window. Before setup it shows onboarding; afterwards a
/// sidebar (design 03) with profiles, accounts, Verify and Settings, each
/// navigating forward and back inside the same window.
struct MainWindowView: View {
    let model: AppModel
    @Bindable var navigator: MainNavigator

    var body: some View {
        VStack(spacing: 0) {
            if model.isTestMode { TestModeBanner() }
            if model.isInstalled {
                NavigationSplitView {
                    sidebar
                } detail: {
                    NavigationStack(path: $navigator.path) {
                        root
                            .navigationDestination(for: Route.self, destination: page)
                    }
                }
            } else {
                OnboardingView(model: model) { navigator.show(model.state.profileId.map { .profile($0) } ?? .claude) }
            }
        }
        .frame(minWidth: 900, minHeight: 580)
        .alert("Não deu certo", isPresented: Binding(get: { model.lastError != nil }, set: { if !$0 { model.lastError = nil } })) {
            Button("Ok") { model.lastError = nil }
        } message: {
            Text(model.lastError ?? "")
        }
    }

    private var sidebar: some View {
        List(selection: $navigator.selection) {
            Section("Perfis") {
                ForEach(model.config.profiles) { profile in
                    HStack {
                        ProfileBadge(icon: profile.icon, color: profile.color, size: 20)
                        Text(profile.name)
                        Spacer()
                        if profile.id == model.state.profileId {
                            Image(systemName: "checkmark").font(.caption).foregroundStyle(.secondary)
                                .accessibilityLabel("ativo")
                        }
                    }
                    .tag(SidebarItem.profile(profile.id))
                }
                Label("Novo perfil", systemImage: "plus").tag(SidebarItem.newProfile)
            }
            Section("Contas") {
                countRow("Git", "arrow.triangle.branch", model.config.gitIdentities.count, warning: false).tag(SidebarItem.git)
                countRow("GitHub", "chevron.left.forwardslash.chevron.right", model.config.githubAccounts.count,
                         warning: model.config.githubAccounts.contains { model.githubLogin(for: $0)?.isUsable == false }).tag(SidebarItem.github)
                countRow("Claude", "sparkle", model.config.claudeAccounts.count,
                         warning: model.config.claudeAccounts.contains { model.claudeStatus($0) == .loggedOut }).tag(SidebarItem.claude)
                countRow("Chaves de API", "key", model.config.apiKeys.count,
                         warning: model.config.apiKeys.contains { !model.hasSecret($0) }).tag(SidebarItem.apiKeys)
            }
            Section("Sistema") {
                HStack {
                    Label("Verificar", systemImage: "checkmark.shield")
                    Spacer()
                    switch model.consistency {
                    case .ok: Circle().fill(.green).frame(width: 7, height: 7).accessibilityLabel("tudo certo")
                    case .problems: Circle().fill(.orange).frame(width: 7, height: 7).accessibilityLabel("inconsistente")
                    case .unknown: EmptyView()
                    }
                }
                .tag(SidebarItem.verify)
                Label("Ajustes", systemImage: "gearshape").tag(SidebarItem.settings)
            }
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 220)
    }

    private func countRow(_ title: String, _ symbol: String, _ count: Int, warning: Bool) -> some View {
        HStack {
            Label(title, systemImage: symbol)
            Spacer()
            Text("\(count)").foregroundStyle(.secondary).monospacedDigit()
            if warning {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.caption)
                    .accessibilityLabel("precisa de atenção")
            }
        }
    }

    @ViewBuilder private var root: some View {
        switch navigator.selection {
        case let .profile(id)?: ProfileEditorPage(model: model, navigator: navigator, profileId: id).id(id)
        case .newProfile?: ProfileEditorPage(model: model, navigator: navigator, profileId: nil).id("new")
        case .git?: GitAccountsPage(model: model, navigator: navigator)
        case .github?: GitHubAccountsPage(model: model, navigator: navigator)
        case .claude?, nil: ClaudeAccountsPage(model: model, navigator: navigator)
        case .apiKeys?: APIKeysPage(model: model, navigator: navigator)
        case .verify?: VerifyPage(model: model, navigator: navigator)
        case .settings?: SettingsPage(model: model, navigator: navigator)
        }
    }

    @ViewBuilder private func page(_ route: Route) -> some View {
        switch route {
        case let .editGit(id): GitIdentityEditorPage(model: model, navigator: navigator, identityId: id)
        case let .editGitHub(id): GitHubAccountEditorPage(model: model, navigator: navigator, accountId: id)
        case let .githubLogin(host):
            if let session = navigator.githubSessions[host] {
                GitHubLoginPage(session: session, model: model, navigator: navigator)
            } else {
                ContentUnavailableView("Login encerrado", systemImage: "xmark.circle")
            }
        case .addClaude: AddClaudeAccountPage(model: model, navigator: navigator)
        case let .claudeLogin(id):
            if let session = navigator.claudeSessions[id] {
                LoginPage(session: session, model: model, navigator: navigator)
            } else {
                ContentUnavailableView("Login encerrado", systemImage: "xmark.circle")
            }
        case let .editAPIKey(id): APIKeyEditorPage(model: model, navigator: navigator, keyId: id)
        case .uninstall: UninstallPage(model: model, navigator: navigator)
        }
    }
}
