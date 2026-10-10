import MultiCredCore
import SwiftUI

// Claude model (D37): a profile owns a Claude *folder* (agents, skills, chats,
// settings). A Claude *account* is only a credential (token from
// `claude setup-token`) that can log in any folder without changing it.

// MARK: - Root

struct ClaudeAccountsPage: View {
    let model: AppModel
    let navigator: MainNavigator
    @State private var summaries = ClaudeFolderSummaries()
    @State private var pendingRemoval: ClaudeAccount?

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Claude", subtitle: "Pastas guardam agents, skills e conversas. Contas são só o login usado nelas.") {
                Button { navigator.push(.addClaude) } label: { Label("Adicionar conta", systemImage: "plus") }
                    .buttonStyle(.borderedProminent)
            }
            Divider()
            List {
                Section {
                    ForEach(model.claudeFoldersInUse, id: \.self) { dir in
                        folderRow(dir)
                            .contentShape(Rectangle())
                            .onTapGesture { navigator.push(.claudeFolder(dir)) }
                    }
                } header: {
                    Text("Pastas dos perfis")
                } footer: {
                    Text("Cada perfil usa uma pasta. Trocar a conta não muda a pasta.").font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    if model.config.claudeAccounts.isEmpty {
                        Text("Nenhuma conta extra. Adicione uma para usar o login de outra pessoa ou de outra assinatura sem trocar de pasta.")
                            .foregroundStyle(.secondary).font(.callout)
                    }
                    ForEach(model.config.claudeAccounts) { account in
                        accountRow(account)
                            .contentShape(Rectangle())
                            .onTapGesture { navigator.push(.claudeAccount(account.id)) }
                            .contextMenu {
                                Button("Usar agora no perfil ativo") { useNow(account.id) }
                                Button("Trocar token…") { navigator.push(.replaceClaudeToken(account.id)) }
                                Divider()
                                Button("Remover conta…", role: .destructive) { pendingRemoval = account }
                            }
                    }
                } header: {
                    Text("Contas Claude (só credencial)")
                }
            }
            .listStyle(.inset)
            InfoNote(text: "O token de cada conta fica só no Keychain e vale nos terminais (CLAUDE_CODE_OAUTH_TOKEN). Apps gráficos continuam com o login da pasta.", symbol: "lock")
                .padding(20)
        }
        .navigationTitle("Claude")
        .task {
            await model.refreshClaudeStatuses()
            await summaries.load(configDirs: model.claudeFoldersInUse, environment: model.environment)
        }
        .modifier(ClaudeRemovalDialog(model: model, pending: $pendingRemoval))
    }

    private func folderRow(_ dir: String?) -> some View {
        let profiles = model.config.profiles.filter { $0.claudeConfigDir == dir }
        let summary = summaries.summary(for: dir, environment: model.environment)
        return HStack(spacing: 12) {
            Image(systemName: "folder").font(.title3).foregroundStyle(.secondary).frame(width: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.folderName(dir)).font(.headline.monospaced())
                Text(profiles.isEmpty ? "Pasta padrão (nenhum perfil)" : "Perfis: \(profiles.map(\.name).joined(separator: ", "))")
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                if let summary {
                    Text("\(summary.projectCount) projetos · \(summary.conversationCount) conversas")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                if let status = model.folderStatus(dir) {
                    StatusPill(text: folderPill(status).0, tone: folderPill(status).1)
                    if !status.isLoggedIn {
                        Button("Entrar…") { navigator.showClaudeFolderLogin(dir) }.controlSize(.small)
                    }
                } else {
                    ProgressView().controlSize(.small)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func accountRow(_ account: ClaudeAccount) -> some View {
        let inUse = model.state.appliedClaudeAccountId == account.id
        return AccountRow(
            name: account.nickname, color: account.color, title: account.nickname,
            subtitle: account.email ?? "conta Claude",
            usedIn: usedIn(model.profilesUsing(claudeAccount: account.id)),
            detail: model.hasToken(account) ? "token no Keychain" : "sem token"
        ) {
            VStack(alignment: .trailing, spacing: 4) {
                if inUse {
                    StatusPill(text: "Em uso", tone: .ok)
                } else if !model.hasToken(account) {
                    StatusPill(text: "Sem token", tone: .error)
                } else {
                    Button("Usar agora") { useNow(account.id) }
                        .controlSize(.small)
                        .disabled(model.activeProfile == nil || model.isSwitching)
                }
            }
        }
    }

    private func useNow(_ id: UUID) {
        Task { if let error = await model.switchClaudeOnly(to: id) { model.lastError = error } }
    }
}

func folderPill(_ status: ClaudeLoginStatus) -> (String, PillTone) {
    switch status {
    case let .loggedIn(email?): (email, .ok)
    case .loggedIn: ("Logada", .ok)
    case .loggedOut: ("Sem login", .warning)
    default: status.pill
    }
}

private struct ClaudeRemovalDialog: ViewModifier {
    let model: AppModel
    @Binding var pending: ClaudeAccount?
    var onRemoved: () -> Void = {}

    func body(content: Content) -> some View {
        content.confirmationDialog(
            "Remover a conta \(pending?.nickname ?? "")?",
            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
            presenting: pending
        ) { account in
            Button("Remover", role: .destructive) {
                model.removeClaudeAccount(account.id)
                onRemoved()
            }
        } message: { account in
            let used = model.profilesUsing(claudeAccount: account.id).map(\.name)
            Text((used.isEmpty ? "" : "Usada em: \(used.joined(separator: ", ")). Esses perfis voltam a usar o login da própria pasta. ")
                + "O token é apagado do Keychain. Nenhuma pasta ou conversa é tocada.")
        }
    }
}

// MARK: - Folder

struct ClaudeFolderDetailPage: View {
    let model: AppModel
    let navigator: MainNavigator
    let configDir: String?

    @State private var summaries = ClaudeFolderSummaries()
    @State private var confirmLogout = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "folder").font(.largeTitle).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.folderName(configDir)).font(.title2.weight(.semibold).monospaced())
                    let used = model.config.profiles.filter { $0.claudeConfigDir == configDir }.map(\.name)
                    Text(used.isEmpty ? "Nenhum perfil usa esta pasta." : "Perfis: \(used.joined(separator: ", "))")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let status = model.folderStatus(configDir) {
                    StatusPill(text: folderPill(status).0, tone: folderPill(status).1)
                }
            }
            if let summary = summaries.summary(for: configDir, environment: model.environment) {
                ClaudeFolderPreview(summary: summary)
            } else {
                ProgressView("Lendo a pasta…")
            }
            Text("Login da pasta: a conta usada quando o perfil não escolhe uma conta Claude extra (e sempre nos apps gráficos).")
                .font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            HStack {
                Button("Sair do login da pasta…") { confirmLogout = true }
                    .disabled(model.folderStatus(configDir)?.isLoggedIn != true)
                Spacer()
                Button("Entrar…") { navigator.showClaudeFolderLogin(configDir) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .navigationTitle(model.folderName(configDir))
        .task {
            await summaries.load(configDirs: [configDir], environment: model.environment)
            await model.refreshFolderStatus(configDir, force: false)
        }
        .confirmationDialog(configDir == nil ? "Sair do seu login principal do Claude Code (~/.claude)?" : "Sair do login de \(model.folderName(configDir))?",
                            isPresented: $confirmLogout) {
            Button("Sair", role: configDir == nil ? .destructive : nil) {
                Task {
                    if let error = await model.logoutClaudeFolder(configDir) { model.lastError = error }
                    await summaries.load(configDirs: [configDir], environment: model.environment)
                }
            }
        } message: {
            Text(configDir == nil
                 ? "~/.claude é a pasta padrão do Claude Code. O login dela será apagado e será preciso entrar de novo. Conversas, agents e skills ficam."
                 : "O Claude Code apaga o login desta pasta. Conversas, agents e skills ficam; para usar de novo, entre outra vez.")
        }
    }
}

// MARK: - Account

struct ClaudeAccountDetailPage: View {
    let model: AppModel
    let navigator: MainNavigator
    let accountId: UUID

    @State private var pendingRemoval: ClaudeAccount?

    var body: some View {
        if let account = model.config.claudeAccount(accountId) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    AccountAvatar(name: account.nickname, color: account.color, size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.nickname).font(.title2.weight(.semibold))
                        Text(account.email ?? "e-mail não informado").foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.state.appliedClaudeAccountId == account.id {
                        StatusPill(text: "Em uso", tone: .ok)
                    } else {
                        StatusPill(text: model.hasToken(account) ? "Token salvo" : "Sem token", tone: model.hasToken(account) ? .ok : .error)
                    }
                }
                let used = model.profilesUsing(claudeAccount: account.id).map(\.name)
                Text(used.isEmpty ? "Nenhum perfil usa esta conta por padrão." : "Padrão nos perfis: \(used.joined(separator: ", ")).")
                    .foregroundStyle(.secondary)
                if let profile = model.activeProfile {
                    Text("\"Usar agora\" mantém o perfil \(profile.name) e a pasta \(model.folderName(profile.claudeConfigDir)) (agents, skills, conversas). Só o login muda, até a próxima troca de perfil.")
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                HStack {
                    Button("Remover conta…", role: .destructive) { pendingRemoval = account }.foregroundStyle(.red)
                    Button("Trocar token…") { navigator.push(.replaceClaudeToken(account.id)) }
                    Spacer()
                    Button("Usar agora") {
                        Task { if let error = await model.switchClaudeOnly(to: account.id) { model.lastError = error } }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.activeProfile == nil || model.state.appliedClaudeAccountId == account.id || model.isSwitching || !model.hasToken(account))
                }
            }
            .padding(20)
            .navigationTitle(account.nickname)
            .modifier(ClaudeRemovalDialog(model: model, pending: $pendingRemoval) { navigator.back() })
        } else {
            ContentUnavailableView("Conta removida", systemImage: "xmark.circle")
        }
    }
}

// MARK: - Add account / replace token

struct AddClaudeAccountPage: View {
    let model: AppModel
    let navigator: MainNavigator
    /// nil = new account; otherwise only its token is replaced.
    var replacing: UUID?

    private enum Source: Hashable { case browser, paste }

    @State private var nickname = ""
    @State private var email = ""
    @State private var color: ProfileColor = .teal
    @State private var source: Source = .browser
    @State private var pasted = ""
    @State private var session: SetupTokenSession?
    @State private var code = ""
    @State private var saved: ClaudeAccount?
    @State private var startError: String?

    private var existing: ClaudeAccount? { replacing.flatMap { model.config.claudeAccount($0) } }
    private var canStart: Bool { existing != nil || !nickname.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let saved {
                    done(saved)
                } else {
                    form
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(existing.map { "Novo token de \($0.nickname)" } ?? "Adicionar conta Claude")
        .onDisappear { session?.stop() }
    }

    @ViewBuilder private var form: some View {
        Text("Uma conta Claude aqui é só o login. Ela não tem pasta própria: usada num perfil, mantém os agents, skills e conversas da pasta do perfil.")
            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

        if existing == nil {
            Form {
                TextField("Apelido", text: $nickname, prompt: Text("Ex.: Marco"))
                TextField("E-mail da conta (opcional)", text: $email, prompt: Text("marco@empresa.com"))
                LabeledContent("Cor") { ColorChooser(selection: $color) }
            }
            .formStyle(.grouped)
            .disabled(session != nil)
        }

        Picker("Como obter o token", selection: $source) {
            Text("Entrar pelo navegador").tag(Source.browser)
            Text("Colar um token").tag(Source.paste)
        }
        .pickerStyle(.segmented)
        .disabled(session != nil)

        switch source {
        case .browser: browserFlow
        case .paste: pasteFlow
        }

        if let startError {
            Text(startError).font(.callout).foregroundStyle(.red)
        }
        HStack {
            Spacer()
            Button("Cancelar") {
                session?.stop()
                navigator.back()
            }
        }
    }

    @ViewBuilder private var browserFlow: some View {
        if let session {
            VStack(alignment: .leading, spacing: 10) {
                Text(browserMessage(session)).font(.callout)
                    .foregroundStyle(session.phase.isFailure ? .red : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                TerminalOutput(directory: "pasta temporária (apagada no fim)",
                               command: model.claudeLoginMode == .simulated ? "claude setup-token (simulado)" : "claude setup-token",
                               text: session.output)
                if !session.phase.isFinished {
                    HStack {
                        SecureField("Código do navegador, se pedir", text: $code)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(sendCode)
                        Button("Enviar", action: sendCode).disabled(code.isEmpty || !session.phase.acceptsCode)
                        if model.claudeLoginMode != .simulated {
                            Button("Copiar link") { session.copyLink() }.disabled(session.authorizationURL == nil)
                            Button("Abrir navegador de novo") { session.openBrowserAgain() }.disabled(session.authorizationURL == nil)
                        }
                    }
                } else if session.phase.isFailure {
                    Button("Tentar de novo") { start() }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Label("Vai abrir o navegador. Entre com a conta que você quer usar. Se o navegador já estiver logado em outra conta Claude, saia antes ou copie o link para uma janela anônima.", systemImage: "info.circle")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if model.claudeLoginMode == .simulated {
                    Label("Modo de teste: simulado, gera um token falso.", systemImage: "testtube.2").font(.callout).foregroundStyle(.orange)
                }
                Button("Entrar pelo navegador") { start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canStart)
            }
        }
    }

    @ViewBuilder private var pasteFlow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Num terminal, rode \"claude setup-token\", entre com a conta e cole aqui a linha que começa com sk-ant-oat.")
                .font(.callout).foregroundStyle(.secondary)
            SecureField("sk-ant-oat01-…", text: $pasted)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
            HStack {
                Spacer()
                Button("Salvar") { save(token: pasted) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canStart || pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func done(_ account: ClaudeAccount) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(existing != nil ? "Token de \(account.nickname) trocado." : "Conta \(account.nickname) adicionada.", systemImage: "checkmark.circle.fill")
                .font(.title3).foregroundStyle(.green)
            Text("O token está só no Keychain. Escolha esta conta no editor de um perfil, ou use agora no perfil ativo sem trocar de pasta.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                if model.activeProfile != nil {
                    Button("Usar agora em \(model.activeProfile?.name ?? "")") {
                        Task {
                            if let error = await model.switchClaudeOnly(to: account.id) { model.lastError = error } else { navigator.path = [] }
                        }
                    }
                }
                Button("Concluir") { navigator.path = [] }.keyboardShortcut(.defaultAction)
            }
        }
    }

    private func browserMessage(_ session: SetupTokenSession) -> String {
        switch session.phase {
        case .starting, .waitingForBrowser, .waitingForCode:
            "Autorize no navegador. Se ele mostrar um código, cole abaixo."
        case .connecting: "Gerando o token…"
        case .connected: "Token recebido."
        case let .failed(reason): session.launchError ?? "Não deu certo (\(reason))."
        }
    }

    private func start() {
        startError = nil
        session?.stop()
        let new = SetupTokenSession(
            onToken: { token in save(token: token) },
            cleanup: { url in
                // Only the throwaway folder created for this run.
                if url.lastPathComponent.hasPrefix("setup-token-") { try? FileManager.default.removeItem(at: url) }
            }
        )
        session = new
        Task {
            let (command, scratch) = await SetupTokenCommand.make(model: model)
            switch command {
            case let .success(command): new.start(command, scratchFolder: scratch)
            case let .failure(error):
                startError = error.text
                session = nil
            }
        }
    }

    private func sendCode() {
        session?.submit(code: code)
        code = ""
    }

    private func save(token: String) {
        if let existing {
            if model.replaceClaudeToken(of: existing, with: token) { saved = existing }
        } else {
            let mail = email.trimmingCharacters(in: .whitespaces)
            saved = model.addClaudeTokenAccount(nickname: nickname, email: mail.isEmpty ? nil : mail, color: color, token: token)
        }
        pasted = ""
    }
}
