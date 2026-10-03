import MultiCredCore
import SwiftUI

/// Accounts window: the Claude accounts list (design 03) with "add" and
/// "login" as pages pushed in the same window.
struct ClaudeAccountsView: View {
    let model: AppModel
    @Bindable var navigator: AccountsNavigator

    var body: some View {
        VStack(spacing: 0) {
            if model.isTestMode { TestModeBanner() }
            NavigationStack(path: $navigator.path) {
                ClaudeAccountsListPage(model: model, navigator: navigator)
                    .navigationDestination(for: AccountsRoute.self) { route in
                        switch route {
                        case .addClaude:
                            AddClaudeAccountPage(model: model, navigator: navigator)
                        case let .claudeLogin(id):
                            if let session = navigator.sessions[id] {
                                LoginPage(session: session, model: model, navigator: navigator)
                            } else {
                                ContentUnavailableView("Login encerrado", systemImage: "xmark.circle")
                            }
                        }
                    }
            }
        }
        .frame(minWidth: 760, minHeight: 520)
        .alert("Não deu certo", isPresented: Binding(get: { model.lastError != nil }, set: { if !$0 { model.lastError = nil } })) {
            Button("Ok") { model.lastError = nil }
        } message: {
            Text(model.lastError ?? "")
        }
    }
}

struct ClaudeAccountsListPage: View {
    let model: AppModel
    let navigator: AccountsNavigator
    @State private var pendingRemoval: ClaudeAccount?
    @State private var pendingLogout: ClaudeAccount?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Contas Claude").font(.title2.weight(.semibold))
                Spacer()
                Button {
                    navigator.showAddClaude()
                } label: {
                    Label("Adicionar conta", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(20)
            Divider()

            if model.config.claudeAccounts.isEmpty {
                ContentUnavailableView(
                    "Nenhuma conta Claude",
                    systemImage: "sparkle",
                    description: Text("Adicione a conta que você já usa (~/.claude) ou crie uma nova pasta para outra conta.")
                )
                .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(model.config.claudeAccounts) { account in
                        row(account)
                            .contextMenu {
                                Button("Entrar…") { navigator.showLogin(account) }
                                Button("Sair da conta…") { pendingLogout = account }
                                Divider()
                                Button("Remover conta…", role: .destructive) { pendingRemoval = account }
                            }
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: false))
            }
            note.padding(20)
        }
        .navigationTitle("Contas Claude")
        .task { await model.refreshClaudeStatuses() }
        .confirmationDialog(
            "Remover a conta \(pendingRemoval?.nickname ?? "")?",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            presenting: pendingRemoval
        ) { account in
            Button("Remover", role: .destructive) { model.removeClaudeAccount(account.id) }
        } message: { account in
            let used = model.profilesUsing(account.id).map(\.name)
            Text((used.isEmpty ? "" : "Usada em: \(used.joined(separator: ", ")). Esses perfis deixam de trocar o Claude. ")
                + "A pasta e o login continuam no seu Mac. Para apagar o login, use \"Sair da conta\" antes.")
        }
        .confirmationDialog(
            "Sair da conta \(pendingLogout?.nickname ?? "")?",
            isPresented: Binding(get: { pendingLogout != nil }, set: { if !$0 { pendingLogout = nil } }),
            presenting: pendingLogout
        ) { account in
            Button("Sair da conta") {
                Task {
                    if let error = await model.logoutClaudeAccount(account.id) { model.lastError = error }
                }
            }
        } message: { _ in
            Text("O Claude Code apaga o login desta conta (só desta pasta). Para usá-la de novo, será preciso entrar outra vez.")
        }
    }

    private func row(_ account: ClaudeAccount) -> some View {
        HStack(spacing: 12) {
            AccountAvatar(name: account.nickname, color: account.color, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(account.nickname).font(.headline)
                Text(account.email ?? "e-mail aparece depois do login").font(.subheadline).foregroundStyle(.secondary)
            }
            .frame(width: 230, alignment: .leading)
            Text(usedIn(account)).frame(width: 130, alignment: .leading).foregroundStyle(.secondary)
            Text(account.configDir.map(model.environment.abbreviate) ?? "~/.claude (padrão)")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(width: 160, alignment: .leading)
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                if let status = model.claudeStatus(account) {
                    StatusPill(text: status.pill.0, tone: status.pill.1)
                    if !status.isLoggedIn {
                        Button("Entrar…") { navigator.showLogin(account) }.controlSize(.small)
                    }
                } else {
                    ProgressView().controlSize(.small)
                }
            }
        }
        .padding(.vertical, 6)
    }

    private func usedIn(_ account: ClaudeAccount) -> String {
        let names = model.profilesUsing(account.id).map(\.name)
        return names.isEmpty ? "—" : names.joined(separator: ", ")
    }

    private var note: some View {
        Label {
            Text("Cada conta Claude tem a própria pasta de configuração. O login acontece no navegador, pelo próprio Claude Code. O MultiCred só aponta CLAUDE_CONFIG_DIR para a pasta certa e não lê nem copia tokens.")
        } icon: {
            Image(systemName: "shield")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
    }
}

/// "Adicionar conta Claude" page: nickname, color and which folder it uses.
/// On success the page is replaced by the login page for the new account.
struct AddClaudeAccountPage: View {
    let model: AppModel
    let navigator: AccountsNavigator

    private enum FolderMode: String, CaseIterable, Identifiable {
        case new, existing, standard
        var id: String { rawValue }
    }

    @State private var nickname = ""
    @State private var color: ProfileColor = .teal
    @State private var mode: FolderMode = .new
    @State private var existingPath = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Adicionar conta Claude").font(.title2.weight(.semibold))
            Form {
                TextField("Apelido", text: $nickname, prompt: Text("Cliente X"))
                Picker("Cor", selection: $color) {
                    ForEach(ProfileColor.allCases, id: \.self) { color in
                        Label(color.displayName, systemImage: "circle.fill").foregroundStyle(color.color).tag(color)
                    }
                }
                Picker("Pasta", selection: $mode) {
                    Text("Nova pasta: \(suggestedPath)").tag(FolderMode.new)
                    Text("Pasta que já existe").tag(FolderMode.existing)
                    // Hidden in "real login in test mode": the default account shares
                    // its keychain item with the user's real ~/.claude login.
                    if !hasDefaultAccount, model.claudeLoginMode != .realInSandbox {
                        Text("~/.claude (conta padrão)").tag(FolderMode.standard)
                    }
                }
                .pickerStyle(.radioGroup)
                if mode == .existing {
                    HStack {
                        TextField("Caminho", text: $existingPath, prompt: Text("~/.claude-pessoal"))
                        Button("Escolher…", action: choose)
                    }
                }
            }
            .formStyle(.grouped)
            Text("Depois de adicionar, o login dessa conta abre aqui mesmo.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            HStack {
                Spacer()
                Button("Voltar") { navigator.back() }.keyboardShortcut(.cancelAction)
                Button("Adicionar e entrar", action: add)
                    .keyboardShortcut(.defaultAction)
                    .disabled(nickname.trimmingCharacters(in: .whitespaces).isEmpty || (mode == .existing && existingPath.isEmpty))
            }
        }
        .padding(20)
        .navigationTitle("Adicionar conta Claude")
    }

    private var hasDefaultAccount: Bool { model.config.claudeAccounts.contains { $0.isDefault } }

    private var suggestedPath: String {
        model.environment.abbreviate(ClaudePaths.suggestedConfigDir(nickname: nickname.isEmpty ? "conta" : nickname, environment: model.environment))
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.showsHiddenFiles = true
        panel.directoryURL = model.environment.home
        if panel.runModal() == .OK, let url = panel.url { existingPath = url.path }
    }

    private func add() {
        let folder: ClaudeFolderChoice = switch mode {
        case .new: .new(ClaudePaths.suggestedConfigDir(nickname: nickname, environment: model.environment))
        case .existing: .existing(existingPath)
        case .standard: .defaultFolder
        }
        guard let account = model.addClaudeAccount(nickname: nickname, color: color, folder: folder) else { return }
        navigator.showLogin(account, replacingTop: true)
    }
}
