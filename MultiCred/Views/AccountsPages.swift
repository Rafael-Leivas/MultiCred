import MultiCredCore
import SwiftUI

// MARK: - Shared list chrome

/// One row in an accounts table (design 03): avatar, title/subtitle, columns, trailing status.
struct AccountRow<Trailing: View>: View {
    let name: String
    let color: ProfileColor
    let title: String
    let subtitle: String
    let usedIn: String
    let detail: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            AccountAvatar(name: name, color: color, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(minWidth: 200, maxWidth: 260, alignment: .leading)
            Text(usedIn).foregroundStyle(.secondary).frame(width: 130, alignment: .leading).lineLimit(2)
            Text(detail).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).frame(width: 160, alignment: .leading).lineLimit(2)
            Spacer()
            trailing
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
    }
}

private func usedIn(_ profiles: [Profile]) -> String {
    profiles.isEmpty ? "—" : profiles.map(\.name).joined(separator: ", ")
}

/// "Remover …?" confirmation shared by the account lists.
private struct RemovalDialog: ViewModifier {
    let title: String
    @Binding var isPresented: Bool
    let message: String
    let action: () -> Void

    func body(content: Content) -> some View {
        content.confirmationDialog(title, isPresented: $isPresented) {
            Button("Remover", role: .destructive, action: action)
        } message: {
            Text(message)
        }
    }
}

// MARK: - Git

struct GitAccountsPage: View {
    let model: AppModel
    let navigator: MainNavigator

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Identidades git", subtitle: "Nome e e-mail dos commits (e, se quiser, a chave SSH).") {
                Button { navigator.push(.editGit(nil)) } label: { Label("Adicionar identidade", systemImage: "plus") }
                    .buttonStyle(.borderedProminent)
            }
            Divider()
            if model.config.gitIdentities.isEmpty {
                ContentUnavailableView("Nenhuma identidade git", systemImage: "arrow.triangle.branch",
                                       description: Text("Adicione o nome e o e-mail que cada perfil usa nos commits."))
                    .frame(maxHeight: .infinity)
            } else {
                List(model.config.gitIdentities) { identity in
                    AccountRow(
                        name: identity.nickname, color: identity.color, title: identity.nickname,
                        subtitle: "\(identity.name) · \(identity.email)",
                        usedIn: usedIn(model.config.profiles.filter { $0.gitIdentityId == identity.id }),
                        detail: identity.sshKeyPath.map { model.environment.abbreviate(model.environment.expandTilde($0)) } ?? "SSH padrão"
                    ) {
                        Button("Editar") { navigator.push(.editGit(identity.id)) }.controlSize(.small)
                    }
                    .onTapGesture(count: 2) { navigator.push(.editGit(identity.id)) }
                }
                .listStyle(.inset)
            }
            InfoNote(text: "O MultiCred escreve só o arquivo incluído no fim do seu gitconfig global. O seu ~/.gitconfig continua seu.", symbol: "info.circle")
                .padding(20)
        }
        .navigationTitle("Git")
    }
}

struct GitIdentityEditorPage: View {
    let model: AppModel
    let navigator: MainNavigator
    let identityId: UUID?

    @State private var draft = GitIdentity(nickname: "", name: "", email: "", color: .indigo)
    @State private var loaded = false
    @State private var confirmRemoval = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Apelido", text: $draft.nickname, prompt: Text("Trabalho"))
                    TextField("Nome nos commits", text: $draft.name, prompt: Text("Seu Nome"))
                    TextField("E-mail nos commits", text: $draft.email, prompt: Text("voce@empresa.com"))
                    LabeledContent("Cor") { ColorChooser(selection: $draft.color) }
                }
                Section {
                    HStack {
                        TextField("Chave SSH (opcional)", text: Binding(get: { draft.sshKeyPath ?? "" }, set: { draft.sshKeyPath = $0.isEmpty ? nil : $0 }), prompt: Text("~/.ssh/id_ed25519_trabalho"))
                        Button("Escolher…", action: chooseKey)
                    }
                } footer: {
                    Text("Com uma chave, o git usa core.sshCommand = ssh -i <chave> -o IdentitiesOnly=yes. Sem chave, vale a sua configuração de SSH.")
                }
            }
            .formStyle(.grouped)
            footer
        }
        .navigationTitle(identityId == nil ? "Nova identidade git" : "Editar identidade git")
        .onAppear(perform: load)
        .modifier(RemovalDialog(
            title: "Remover a identidade \(draft.nickname)?",
            isPresented: $confirmRemoval,
            message: "Os perfis que a usam deixam de trocar o git.",
            action: {
                if let identityId, model.edit({ ConfigEditor.removeGitIdentity(identityId, from: $0) }) { navigator.back() }
            }
        ))
    }

    private var footer: some View {
        HStack {
            if identityId != nil {
                Button("Remover", role: .destructive) { confirmRemoval = true }.foregroundStyle(.red)
            }
            Spacer()
            Button("Cancelar") { navigator.back() }.keyboardShortcut(.cancelAction)
            Button("Salvar") {
                if model.edit({ try ConfigEditor.upsert(draft, in: $0) }) { navigator.back() }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(draft.nickname.isEmpty || draft.name.isEmpty || draft.email.isEmpty)
        }
        .padding(20)
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let identityId, let existing = model.config.gitIdentity(identityId) { draft = existing }
    }

    private func chooseKey() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.showsHiddenFiles = true
        panel.directoryURL = model.environment.home.appendingPathComponent(".ssh")
        if panel.runModal() == .OK, let url = panel.url { draft.sshKeyPath = model.environment.abbreviate(url.path) }
    }
}

// MARK: - GitHub

struct GitHubAccountsPage: View {
    let model: AppModel
    let navigator: MainNavigator
    @State private var refreshing = false

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Contas GitHub", subtitle: "Contas logadas no GitHub CLI (gh). A troca usa gh auth switch.") {
                Button {
                    Task {
                        refreshing = true
                        await model.refreshGitHubLogins()
                        refreshing = false
                    }
                } label: { Label("Conferir logins", systemImage: "arrow.clockwise") }
                    .disabled(refreshing)
                Button { navigator.push(.editGitHub(nil)) } label: { Label("Adicionar conta", systemImage: "plus") }
                    .buttonStyle(.borderedProminent)
            }
            Divider()
            if model.config.githubAccounts.isEmpty {
                ContentUnavailableView("Nenhuma conta GitHub", systemImage: "chevron.left.forwardslash.chevron.right",
                                       description: Text("Adicione uma conta que já está no gh ou entre com outra."))
                    .frame(maxHeight: .infinity)
            } else {
                List(model.config.githubAccounts) { account in
                    AccountRow(
                        name: account.nickname, color: account.color, title: account.nickname,
                        subtitle: "\(account.username) · \(account.host)",
                        usedIn: usedIn(model.config.profiles.filter { $0.githubAccountId == account.id }),
                        detail: model.githubLogin(for: account)?.active == true ? "ativa no gh" : ""
                    ) {
                        statusView(account)
                    }
                    .contextMenu {
                        Button("Editar") { navigator.push(.editGitHub(account.id)) }
                        Button("Entrar de novo no GitHub…") { navigator.showGitHubLogin(host: account.host) }
                    }
                    .onTapGesture(count: 2) { navigator.push(.editGitHub(account.id)) }
                }
                .listStyle(.inset)
            }
            InfoNote(text: "O login e o token ficam com o próprio gh (no Keychain dele). O MultiCred só escolhe a conta ativa.").padding(20)
        }
        .navigationTitle("GitHub")
        .task { await model.refreshGitHubLogins() }
    }

    @ViewBuilder private func statusView(_ account: GitHubAccount) -> some View {
        if refreshing {
            ProgressView().controlSize(.small)
        } else if let login = model.githubLogin(for: account) {
            if login.isUsable {
                StatusPill(text: "Conectada", tone: .ok)
            } else {
                VStack(alignment: .trailing, spacing: 4) {
                    StatusPill(text: "Precisa entrar", tone: .warning)
                    Button("Entrar…") { navigator.showGitHubLogin(host: account.host) }.controlSize(.small)
                }
            }
        } else if model.githubLogins.isEmpty {
            StatusPill(text: "Status indisponível", tone: .neutral)
        } else {
            VStack(alignment: .trailing, spacing: 4) {
                StatusPill(text: "Não está no gh", tone: .warning)
                Button("Entrar…") { navigator.showGitHubLogin(host: account.host) }.controlSize(.small)
            }
        }
    }
}

struct GitHubAccountEditorPage: View {
    let model: AppModel
    let navigator: MainNavigator
    let accountId: UUID?

    @State private var draft = GitHubAccount(nickname: "", username: "", color: .indigo)
    @State private var loaded = false
    @State private var confirmRemoval = false

    private var availableLogins: [GitHubLogin] {
        model.githubLogins.filter { login in
            !model.config.githubAccounts.contains { $0.username.caseInsensitiveCompare(login.login) == .orderedSame && $0.host == login.host }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                if accountId == nil {
                    Section("Contas que o gh já conhece") {
                        if availableLogins.isEmpty {
                            Text(model.githubLogins.isEmpty ? "Nenhuma conta encontrada no gh." : "Todas as contas do gh já foram adicionadas.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(availableLogins, id: \.login) { login in
                            Button {
                                draft.username = login.login
                                draft.host = login.host
                                if draft.nickname.isEmpty { draft.nickname = login.login }
                            } label: {
                                HStack {
                                    Image(systemName: draft.username == login.login ? "largecircle.fill.circle" : "circle")
                                    Text("\(login.login) · \(login.host)")
                                    if login.active { Text("ativa").font(.caption).foregroundStyle(.secondary) }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                        Button {
                            navigator.showGitHubLogin(replacingTop: true)
                        } label: {
                            Label("Entrar com outra conta no GitHub…", systemImage: "person.badge.plus")
                        }
                    }
                }
                Section {
                    TextField("Apelido", text: $draft.nickname, prompt: Text("Trabalho"))
                    TextField("Usuário no GitHub", text: $draft.username, prompt: Text("seu-usuario"))
                        .disabled(accountId != nil)
                    TextField("Servidor", text: $draft.host)
                        .disabled(accountId != nil)
                    LabeledContent("Cor") { ColorChooser(selection: $draft.color) }
                }
            }
            .formStyle(.grouped)
            HStack {
                if accountId != nil {
                    Button("Remover", role: .destructive) { confirmRemoval = true }.foregroundStyle(.red)
                }
                Spacer()
                Button("Cancelar") { navigator.back() }.keyboardShortcut(.cancelAction)
                Button("Salvar") {
                    if model.edit({ try ConfigEditor.upsert(draft, in: $0) }) { navigator.back() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draft.nickname.isEmpty || draft.username.isEmpty)
            }
            .padding(20)
        }
        .navigationTitle(accountId == nil ? "Adicionar conta GitHub" : "Editar conta GitHub")
        .onAppear {
            guard !loaded else { return }
            loaded = true
            if let accountId, let existing = model.config.githubAccount(accountId) { draft = existing }
        }
        .task { if model.githubLogins.isEmpty { await model.refreshGitHubLogins() } }
        .modifier(RemovalDialog(
            title: "Remover a conta \(draft.nickname)?",
            isPresented: $confirmRemoval,
            message: "Ela continua logada no gh; os perfis que a usam deixam de trocar o GitHub.",
            action: {
                if let accountId, model.edit({ ConfigEditor.removeGitHubAccount(accountId, from: $0) }) { navigator.back() }
            }
        ))
    }
}

/// "Entrar no GitHub" page: shows gh's one-time code and opens the browser.
struct GitHubLoginPage: View {
    @Bindable var session: GitHubLoginSession
    let model: AppModel
    let navigator: MainNavigator
    @State private var showOutput = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.title2)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(Color.primary.opacity(0.08)))
                VStack(alignment: .leading) {
                    Text("Entrar no GitHub").font(.headline)
                    Text(session.host).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                StatusPill(text: title, tone: tone)
            }
            if model.isTestMode {
                Label("Simulação do modo de teste: o navegador não abre e nenhum login real acontece.", systemImage: "testtube.2")
                    .font(.callout).foregroundStyle(.orange)
            }
            content
            if showOutput || isFailure {
                TerminalOutput(directory: "~", command: model.isTestMode ? "gh auth login (simulado)" : "gh auth login --web", text: session.output)
            }
            Spacer(minLength: 0)
            HStack {
                Button { showOutput.toggle() } label: {
                    Label(showOutput ? "Ocultar saída" : "Mostrar saída", systemImage: showOutput ? "chevron.down" : "chevron.right")
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                Spacer()
                switch session.phase {
                case .connected:
                    Button("Concluir") { navigator.path = [] }.keyboardShortcut(.defaultAction)
                case .failed:
                    Button("Voltar") { navigator.back() }
                    Button("Tentar de novo") { navigator.showGitHubLogin(host: session.host, replacingTop: true) }.keyboardShortcut(.defaultAction)
                default:
                    Button("Cancelar") {
                        session.cancel()
                        navigator.back()
                    }
                }
            }
        }
        .padding(20)
        .navigationTitle("Entrar no GitHub")
    }

    @ViewBuilder private var content: some View {
        switch session.phase {
        case .starting:
            HStack { ProgressView().controlSize(.small); Text("Iniciando o GitHub CLI…").foregroundStyle(.secondary) }
        case let .showingCode(code), let .waitingForBrowser(code):
            VStack(alignment: .leading, spacing: 10) {
                Text("1. Copie este código. 2. Abra o GitHub e cole o código. 3. Autorize o GitHub CLI.")
                    .foregroundStyle(.secondary)
                HStack(spacing: 14) {
                    Text(code).font(.system(size: 30, weight: .semibold, design: .monospaced)).textSelection(.enabled)
                    Button("Copiar código e abrir o GitHub") { session.openBrowser() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!isShowingCode)
                }
                if !isShowingCode {
                    HStack { ProgressView().controlSize(.small); Text("Aguardando a autorização no navegador…").foregroundStyle(.secondary) }
                }
            }
        case let .connected(login):
            Label("Pronto: \(login ?? "conta") está logada no gh. A conta ativa voltou para a do perfil atual.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case let .failed(reason):
            Text(session.launchError ?? "Não deu certo (\(reason)).").foregroundStyle(.red)
        }
    }

    private var isShowingCode: Bool {
        if case .showingCode = session.phase { return true }
        return false
    }

    private var isFailure: Bool {
        if case .failed = session.phase { return true }
        return false
    }

    private var title: String {
        switch session.phase {
        case .starting: "Iniciando"
        case .showingCode: "Aguardando você"
        case .waitingForBrowser: "Aguardando navegador"
        case .connected: "Conectada"
        case .failed: "Erro"
        }
    }

    private var tone: PillTone {
        switch session.phase {
        case .connected: .ok
        case .failed: .error
        default: .warning
        }
    }
}

// MARK: - Claude

struct ClaudeAccountsPage: View {
    let model: AppModel
    let navigator: MainNavigator
    @State private var pendingRemoval: ClaudeAccount?
    @State private var pendingLogout: ClaudeAccount?

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Contas Claude", subtitle: "Cada conta usa a própria pasta de configuração do Claude Code.") {
                Button { navigator.push(.addClaude) } label: { Label("Adicionar conta", systemImage: "plus") }
                    .buttonStyle(.borderedProminent)
            }
            Divider()
            if model.config.claudeAccounts.isEmpty {
                ContentUnavailableView("Nenhuma conta Claude", systemImage: "sparkle",
                                       description: Text("Adicione a conta que você já usa (~/.claude) ou crie uma nova pasta para outra conta."))
                    .frame(maxHeight: .infinity)
            } else {
                List(model.config.claudeAccounts) { account in
                    AccountRow(
                        name: account.nickname, color: account.color, title: account.nickname,
                        subtitle: account.email ?? "e-mail aparece depois do login",
                        usedIn: usedIn(model.profilesUsing(claudeAccount: account.id)),
                        detail: account.configDir.map(model.environment.abbreviate) ?? "~/.claude (padrão)"
                    ) {
                        VStack(alignment: .trailing, spacing: 4) {
                            if let status = model.claudeStatus(account) {
                                StatusPill(text: status.pill.0, tone: status.pill.1)
                                if !status.isLoggedIn {
                                    Button("Entrar…") { navigator.showClaudeLogin(account) }.controlSize(.small)
                                }
                            } else {
                                ProgressView().controlSize(.small)
                            }
                        }
                    }
                    .onTapGesture { navigator.push(.claudeAccount(account.id)) }
                    .contextMenu {
                        Button("Ver pasta e conversas") { navigator.push(.claudeAccount(account.id)) }
                        Button("Entrar…") { navigator.showClaudeLogin(account) }
                        Button("Sair da conta…") { pendingLogout = account }
                        Divider()
                        Button("Remover conta…", role: .destructive) { pendingRemoval = account }
                    }
                }
                .listStyle(.inset)
            }
            InfoNote(text: "O login acontece no navegador, pelo próprio Claude Code. O MultiCred só aponta CLAUDE_CONFIG_DIR para a pasta certa e não lê nem copia tokens. Clique numa conta para ver a pasta e as conversas dela.")
                .padding(20)
        }
        .navigationTitle("Claude")
        .task { await model.refreshClaudeStatuses() }
        .confirmationDialog(
            "Remover a conta \(pendingRemoval?.nickname ?? "")?",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            presenting: pendingRemoval
        ) { account in
            Button("Remover", role: .destructive) { model.removeClaudeAccount(account.id) }
        } message: { account in
            let used = model.profilesUsing(claudeAccount: account.id).map(\.name)
            Text((used.isEmpty ? "" : "Usada em: \(used.joined(separator: ", ")). Esses perfis deixam de trocar o Claude. ")
                + "A pasta e o login continuam no seu Mac. Para apagar o login, use \"Sair da conta\" antes.")
        }
        .confirmationDialog(
            pendingLogout.map(logoutTitle) ?? "",
            isPresented: Binding(get: { pendingLogout != nil }, set: { if !$0 { pendingLogout = nil } }),
            presenting: pendingLogout
        ) { account in
            Button("Sair da conta", role: account.isDefault ? .destructive : nil) {
                Task { if let error = await model.logoutClaudeAccount(account.id) { model.lastError = error } }
            }
        } message: { account in
            Text(logoutMessage(account))
        }
    }
}

struct AddClaudeAccountPage: View {
    let model: AppModel
    let navigator: MainNavigator

    private enum FolderMode: Hashable { case new, existing }

    @State private var nickname = ""
    @State private var color: ProfileColor = .teal
    @State private var mode: FolderMode = .new
    /// Selected existing folder: `.some(nil)` is the default `~/.claude`.
    @State private var selected: String??
    @State private var manualPath = ""
    @State private var summaries = ClaudeFolderSummaries()

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Apelido", text: $nickname, prompt: Text("Trabalho"))
                    LabeledContent("Cor") { ColorChooser(selection: $color) }
                }
                Section("Pasta de configuração") {
                    Picker("Pasta", selection: $mode) {
                        Text("Nova pasta: \(suggestedPath)").tag(FolderMode.new)
                        Text("Pasta que já existe (com as conversas dela)").tag(FolderMode.existing)
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                }
                if mode == .existing {
                    Section {
                        if availableFolders.isEmpty {
                            Text("Nenhuma pasta ~/.claude* livre encontrada. Escolha uma abaixo.").foregroundStyle(.secondary)
                        }
                        ForEach(availableFolders, id: \.self) { folder in
                            folderCard(folder)
                        }
                        HStack {
                            TextField("Outra pasta", text: $manualPath, prompt: Text("~/minha-pasta-claude"))
                                .onChange(of: manualPath) { if !manualPath.isEmpty { selected = nil } }
                            Button("Escolher…", action: choose)
                        }
                    } header: {
                        Text("Pastas encontradas")
                    } footer: {
                        Text("Use as conversas recentes para reconhecer cada conta. Pastas já usadas por outra conta não aparecem.")
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Text(footerText).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Voltar") { navigator.back() }.keyboardShortcut(.cancelAction)
                Button(mode == .new ? "Adicionar e entrar" : "Adicionar", action: add)
                    .keyboardShortcut(.defaultAction)
                    .disabled(nickname.trimmingCharacters(in: .whitespaces).isEmpty || (mode == .existing && selected == nil && manualPath.isEmpty))
            }
            .padding(20)
        }
        .navigationTitle("Adicionar conta Claude")
        .task { await summaries.discover(environment: model.environment) }
    }

    private var footerText: String {
        mode == .new ? "Depois de adicionar, o login dessa conta abre aqui mesmo." : "Se a pasta não tiver login, o login abre em seguida."
    }

    /// Discovered folders no account uses yet. The default folder is hidden in
    /// "real login in test mode" (it shares the keychain item with the real ~/.claude).
    private var availableFolders: [String?] {
        summaries.discovered.filter { folder in
            !model.config.claudeAccounts.contains { $0.configDir == folder }
                && !(folder == nil && model.claudeLoginMode == .realInSandbox)
        }
    }

    private func folderCard(_ folder: String?) -> some View {
        let isSelected = selected == .some(folder) && manualPath.isEmpty
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                Text(folder.map(model.environment.abbreviate) ?? "~/.claude (pasta padrão)")
                    .font(.callout.monospaced().weight(.semibold))
                Spacer()
            }
            if let summary = summaries.summary(for: folder, environment: model.environment) {
                ClaudeFolderPreview(summary: summary, maxConversations: 3)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.1), lineWidth: isSelected ? 2 : 1))
        .contentShape(Rectangle())
        .onTapGesture {
            selected = .some(folder)
            manualPath = ""
            if nickname.isEmpty, let folder {
                nickname = URL(fileURLWithPath: folder).lastPathComponent.replacingOccurrences(of: ".claude-", with: "").capitalized
            }
        }
    }

    private var suggestedPath: String {
        model.environment.abbreviate(ClaudePaths.suggestedConfigDir(nickname: nickname.isEmpty ? "conta" : nickname, environment: model.environment))
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.showsHiddenFiles = true
        panel.directoryURL = model.environment.home
        if panel.runModal() == .OK, let url = panel.url {
            manualPath = url.path
            selected = nil
        }
    }

    private func add() {
        let folder: ClaudeFolderChoice
        if mode == .new {
            folder = .new(ClaudePaths.suggestedConfigDir(nickname: nickname, environment: model.environment))
        } else if !manualPath.isEmpty {
            folder = .existing(manualPath)
        } else if case let .some(choice) = selected {
            folder = choice.map(ClaudeFolderChoice.existing) ?? .defaultFolder
        } else {
            return
        }
        guard let account = model.addClaudeAccount(nickname: nickname, color: color, folder: folder) else { return }
        // A folder that is already logged in only needs to be shown; otherwise log in.
        let summary = ClaudeFolderInspector.summarize(configDir: account.configDir, environment: model.environment, limit: 0)
        if mode == .existing, summary.email != nil {
            navigator.path.removeLast()
            navigator.push(.claudeAccount(account.id))
            Task { await model.refreshClaudeStatus(account.id) }
        } else {
            navigator.showClaudeLogin(account, replacingTop: true)
        }
    }
}

// MARK: - API keys

struct APIKeysPage: View {
    let model: AppModel
    let navigator: MainNavigator

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Chaves de API", subtitle: "Exportadas como variáveis de ambiente nos terminais do perfil.") {
                Button { navigator.push(.editAPIKey(nil)) } label: { Label("Adicionar chave", systemImage: "plus") }
                    .buttonStyle(.borderedProminent)
            }
            Divider()
            if model.config.apiKeys.isEmpty {
                ContentUnavailableView("Nenhuma chave", systemImage: "key",
                                       description: Text("Adicione chaves da OpenAI, Gemini e outras. O valor fica só no Keychain."))
                    .frame(maxHeight: .infinity)
            } else {
                List(model.config.apiKeys) { key in
                    AccountRow(
                        name: key.nickname, color: key.color, title: key.nickname,
                        subtitle: key.provider.displayName,
                        usedIn: usedIn(model.config.profiles.filter { $0.apiKeyIds.contains(key.id) }),
                        detail: key.envVar
                    ) {
                        if model.hasSecret(key) {
                            StatusPill(text: "No Keychain", tone: .ok)
                        } else {
                            StatusPill(text: "Sem valor", tone: .warning)
                        }
                    }
                    .onTapGesture(count: 2) { navigator.push(.editAPIKey(key.id)) }
                    .contextMenu { Button("Editar") { navigator.push(.editAPIKey(key.id)) } }
                }
                .listStyle(.inset)
            }
            InfoNote(text: "O valor de cada chave fica só no Keychain do macOS. O MultiCred guarda apenas o nome da variável e qual item usar; o terminal lê o valor quando o perfil muda. As chaves não são passadas para apps gráficos.", symbol: "key")
                .padding(20)
        }
        .navigationTitle("Chaves de API")
    }
}

struct APIKeyEditorPage: View {
    let model: AppModel
    let navigator: MainNavigator
    let keyId: UUID?

    @State private var nickname = ""
    @State private var provider: APIProvider = .openai
    @State private var envVar = APIProvider.openai.defaultEnvVar
    @State private var color: ProfileColor = .indigo
    @State private var secret = ""
    @State private var loaded = false
    @State private var confirmRemoval = false

    private var existing: APIKeyAccount? { keyId.flatMap(model.config.apiKey) }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Apelido", text: $nickname, prompt: Text("Trabalho"))
                    Picker("Provedor", selection: $provider) {
                        ForEach(APIProvider.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .onChange(of: provider) { old, new in
                        if envVar.isEmpty || envVar == old.defaultEnvVar { envVar = new.defaultEnvVar }
                    }
                    TextField("Variável de ambiente", text: $envVar, prompt: Text("OPENAI_API_KEY"))
                        .font(.system(.body, design: .monospaced))
                    LabeledContent("Cor") { ColorChooser(selection: $color) }
                }
                Section {
                    SecureField(existing == nil ? "Cole a chave" : "Cole uma nova chave para substituir", text: $secret)
                        .font(.system(.body, design: .monospaced))
                } footer: {
                    Text(existing.map { model.hasSecret($0) ? "Há uma chave guardada no Keychain. Deixe em branco para mantê-la." : "Não há valor no Keychain para esta chave." }
                         ?? "O valor vai direto para o Keychain do macOS e não aparece mais aqui.")
                }
            }
            .formStyle(.grouped)
            HStack {
                if keyId != nil {
                    Button("Remover", role: .destructive) { confirmRemoval = true }.foregroundStyle(.red)
                }
                Spacer()
                Button("Cancelar") { navigator.back() }.keyboardShortcut(.cancelAction)
                Button("Salvar", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(nickname.isEmpty || envVar.isEmpty || (existing == nil && secret.isEmpty))
            }
            .padding(20)
        }
        .navigationTitle(keyId == nil ? "Nova chave de API" : "Editar chave de API")
        .onAppear(perform: load)
        .onDisappear { secret = "" }
        .modifier(RemovalDialog(
            title: "Remover a chave \(nickname)?",
            isPresented: $confirmRemoval,
            message: "O valor é apagado do Keychain e os perfis deixam de exportar \(envVar).",
            action: {
                if let keyId, model.edit({ try ConfigEditor.removeAPIKey(keyId, from: $0, keychain: model.environment.keychain) }) { navigator.back() }
            }
        ))
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let existing {
            nickname = existing.nickname
            provider = existing.provider
            envVar = existing.envVar
            color = existing.color
        }
    }

    private func save() {
        if var existing {
            existing.nickname = nickname
            existing.provider = provider
            existing.envVar = envVar
            existing.color = color
            guard model.edit({ try ConfigEditor.updateAPIKey(existing, in: $0) }) else { return }
            if !secret.isEmpty, !model.replaceSecret(of: existing, with: secret) { return }
        } else {
            guard model.addAPIKey(nickname: nickname, provider: provider, envVar: envVar, secret: secret, color: color) != nil else { return }
        }
        secret = ""
        navigator.back()
    }
}
