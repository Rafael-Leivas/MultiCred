import MultiCredCore
import SwiftUI

/// Claude accounts list (the "Claude" section of design 03). Phase 4 places it
/// inside the full Accounts window with the sidebar.
struct ClaudeAccountsView: View {
    let model: AppModel
    let openLogin: (ClaudeAccount) -> Void

    @State private var showingAdd = false
    @State private var pendingRemoval: ClaudeAccount?

    var body: some View {
        VStack(spacing: 0) {
            if model.isTestMode { TestModeBanner() }
            HStack {
                Text("Contas Claude").font(.title2.weight(.semibold))
                Spacer()
                Button {
                    showingAdd = true
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
                                Button("Entrar…") { openLogin(account) }
                                Divider()
                                Button("Remover conta…", role: .destructive) { pendingRemoval = account }
                            }
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: false))
            }

            note.padding(20)
        }
        .frame(minWidth: 720, minHeight: 420)
        .task { await model.refreshClaudeStatuses() }
        .sheet(isPresented: $showingAdd) {
            AddClaudeAccountSheet(model: model) { account in
                showingAdd = false
                if let account { openLogin(account) }
            }
        }
        .confirmationDialog(
            "Remover a conta \(pendingRemoval?.nickname ?? "")?",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            presenting: pendingRemoval
        ) { account in
            Button("Remover", role: .destructive) { model.removeClaudeAccount(account.id) }
        } message: { account in
            let used = model.profilesUsing(account.id).map(\.name)
            Text((used.isEmpty ? "" : "Usada em: \(used.joined(separator: ", ")). Esses perfis deixam de trocar o Claude. ")
                + "A pasta e o login continuam no seu Mac.")
        }
        .alert("Não deu certo", isPresented: Binding(get: { model.lastError != nil }, set: { if !$0 { model.lastError = nil } })) {
            Button("Ok") { model.lastError = nil }
        } message: {
            Text(model.lastError ?? "")
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
            Text(folder(account))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(width: 160, alignment: .leading)
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                if let status = model.claudeStatus(account) {
                    StatusPill(text: status.pill.0, tone: status.pill.1)
                    if !status.isLoggedIn {
                        Button("Entrar…") { openLogin(account) }.controlSize(.small)
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

    private func folder(_ account: ClaudeAccount) -> String {
        account.configDir.map(model.environment.abbreviate) ?? "~/.claude (padrão)"
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

/// Sheet for a new account: nickname, color and which folder it uses.
struct AddClaudeAccountSheet: View {
    let model: AppModel
    let onDone: (ClaudeAccount?) -> Void

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
            Text("Adicionar conta Claude").font(.title3.weight(.semibold))
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
                    if !hasDefaultAccount { Text("~/.claude (conta padrão)").tag(FolderMode.standard) }
                }
                .pickerStyle(.radioGroup)
                if mode == .existing {
                    HStack {
                        TextField("Caminho", text: $existingPath, prompt: Text("~/.claude-pessoal"))
                        Button("Escolher…", action: choose)
                    }
                }
            }
            Text("Depois de adicionar, a janela de login abre para você entrar nessa conta.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancelar") { onDone(nil) }.keyboardShortcut(.cancelAction)
                Button("Adicionar", action: add)
                    .keyboardShortcut(.defaultAction)
                    .disabled(nickname.trimmingCharacters(in: .whitespaces).isEmpty || (mode == .existing && existingPath.isEmpty))
            }
        }
        .padding(20)
        .frame(width: 480)
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
        onDone(account)
    }
}
