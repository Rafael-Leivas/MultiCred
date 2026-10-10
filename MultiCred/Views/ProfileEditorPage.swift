import MultiCredCore
import SwiftUI

/// Profile editor (design 04). Also used for a new profile.
struct ProfileEditorPage: View {
    let model: AppModel
    let navigator: MainNavigator
    let profileId: UUID?

    @State private var draft = Profile(name: "", color: .indigo)
    @State private var loadedFor: UUID??
    @State private var confirmDeletion = false
    @State private var folders = ClaudeFolderSummaries()
    @State private var newFolderPath: String?

    private var isNew: Bool { profileId == nil }
    private var position: Int? { profileId.flatMap { id in model.config.profiles.firstIndex { $0.id == id } } }

    var body: some View {
        VStack(spacing: 0) {
            header
            Form {
                Section {
                    TextField("Nome", text: $draft.name, prompt: Text("Trabalho"))
                    LabeledContent("Cor") { ColorChooser(selection: $draft.color) }
                    LabeledContent("Ícone") {
                        IconChooser(selection: $draft.icon, letter: draft.name.isEmpty ? "?" : draft.name, color: draft.color)
                    }
                }
                Section("Composição") {
                    picker("Git", symbol: "arrow.triangle.branch", selection: $draft.gitIdentityId,
                           options: model.config.gitIdentities.map { ($0.id, "\($0.nickname) · \($0.email)", $0.color) })
                    picker("GitHub", symbol: "chevron.left.forwardslash.chevron.right", selection: $draft.githubAccountId,
                           options: model.config.githubAccounts.map { ($0.id, "\($0.username) · \($0.host)", $0.color) })
                    claudeSection
                    ForEach(providers, id: \.self) { provider in
                        picker(provider.displayName, symbol: "key", selection: keyBinding(provider),
                               options: model.config.apiKeys.filter { $0.provider == provider }.map { ($0.id, "\($0.nickname) · \($0.envVar)", $0.color) })
                    }
                }
                Section {
                } footer: {
                    Text("“Nenhuma” deixa aquele item como está ao trocar para este perfil (o Claude sempre usa a pasta do perfil). Chaves de API ficam no Keychain do macOS; o perfil guarda só qual item usar.")
                }
            }
            .formStyle(.grouped)
            footer
        }
        .navigationTitle(isNew ? "Novo perfil" : "Editar perfil")
        .onAppear(perform: load)
        .task { await folders.discover(environment: model.environment) }
        .onChange(of: profileId) { load() }
        .confirmationDialog("Apagar o perfil \(draft.name)?", isPresented: $confirmDeletion) {
            Button("Apagar perfil", role: .destructive) {
                if let profileId, model.edit({ ConfigEditor.removeProfile(profileId, from: $0) }) {
                    navigator.show(model.config.profiles.first.map { .profile($0.id) } ?? .claude)
                }
            }
        } message: {
            Text("As contas continuam cadastradas. Se ele estiver ativo, o sistema fica como está até você escolher outro perfil.")
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            ProfileBadge(icon: draft.icon, color: draft.color, size: 64)
            VStack(alignment: .leading, spacing: 4) {
                Text(draft.name.isEmpty ? "Novo perfil" : draft.name).font(.title2.weight(.semibold))
                HStack(spacing: 6) {
                    Text("Na barra de menus:").foregroundStyle(.secondary)
                    if let position, position < 9 {
                        Text("⌘\(position + 1) no menu").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            HStack(spacing: 8) {
                ProfileBadge(icon: draft.icon, color: draft.color, size: 18)
                Text(Date.now, format: .dateTime.hour().minute()).font(.callout.monospacedDigit())
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
            .accessibilityLabel("Prévia na barra de menus")
        }
        .padding(20)
    }

    private var footer: some View {
        HStack {
            if !isNew {
                Button("Apagar perfil", role: .destructive) { confirmDeletion = true }.foregroundStyle(.red)
            }
            Spacer()
            if !isNew, model.state.profileId != profileId {
                Button("Ativar este perfil") {
                    Task { if let error = await model.switchProfile(draft.id) { model.lastError = error } }
                }
                .disabled(model.isSwitching)
            }
            Button("Cancelar") {
                if isNew { navigator.show(model.config.profiles.first.map { .profile($0.id) } ?? .claude) } else { load(force: true) }
            }
            .keyboardShortcut(.cancelAction)
            Button("Salvar") {
                var profile = draft
                profile.name = profile.name.trimmingCharacters(in: .whitespaces)
                if case .letter = profile.icon { profile.icon = .letter(String(profile.name.prefix(1)).uppercased()) }
                if model.edit({ try ConfigEditor.upsert(profile, in: $0) }) {
                    if isNew { navigator.show(.profile(profile.id)) }
                    if model.state.profileId == profile.id {
                        Task { await model.switchProfile(profile.id) }
                    }
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(20)
    }

    /// Claude folder (agents, skills, chats) + which login to use in it.
    @ViewBuilder private var claudeSection: some View {
        Picker(selection: folderBinding) {
            ForEach(folderOptions, id: \.self) { dir in
                Text(folderLabel(dir)).tag(FolderTag.folder(dir))
            }
            Divider()
            Text("Nova pasta…").tag(FolderTag.new)
        } label: {
            Label("Pasta do Claude", systemImage: "folder")
        }
        if let path = newFolderPath {
            HStack {
                TextField("Caminho", text: Binding(get: { path }, set: { newFolderPath = $0 }))
                    .font(.body.monospaced())
                Button("Criar") {
                    if let dir = model.prepareClaudeFolder(.new(path)) {
                        draft.claudeConfigDir = dir
                        newFolderPath = nil
                        Task { await folders.discover(environment: model.environment) }
                    }
                }
                Button("Cancelar") { newFolderPath = nil }
            }
        }
        Picker(selection: $draft.claudeAccountId) {
            Text(folderLoginLabel).tag(UUID?.none)
            ForEach(model.config.claudeAccounts) { account in
                Label {
                    Text("\(account.nickname)\(account.email.map { " · \($0)" } ?? "")")
                } icon: {
                    Image(systemName: "circle.fill").foregroundStyle(account.color.color)
                }
                .tag(UUID?.some(account.id))
            }
        } label: {
            Label("Conta Claude", systemImage: "sparkle")
        }
        Text("A pasta guarda agents, skills e conversas. A conta é só o login: trocar a conta não muda a pasta.")
            .font(.caption).foregroundStyle(.secondary)
        if draft.claudeAccountId == nil, model.folderStatus(draft.claudeConfigDir) == .loggedOut {
            HStack {
                Label("A pasta \(model.folderName(draft.claudeConfigDir)) não tem login.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                Spacer()
                Button("Entrar…") { navigator.showClaudeFolderLogin(draft.claudeConfigDir) }.controlSize(.small)
            }
        }
    }

    private enum FolderTag: Hashable { case folder(String?), new }

    private var folderBinding: Binding<FolderTag> {
        Binding(
            get: { .folder(draft.claudeConfigDir) },
            set: { tag in
                switch tag {
                case let .folder(dir): draft.claudeConfigDir = dir
                case .new: newFolderPath = "~/.claude-\(slug(draft.name))"
                }
            }
        )
    }

    private var folderOptions: [String?] {
        var options: [String?] = [nil]
        for dir in folders.discovered + model.config.profiles.map(\.claudeConfigDir) + [draft.claudeConfigDir]
        where !options.contains(dir) && dir != ClaudePaths.defaultConfigDir(environment: model.environment) {
            options.append(dir)
        }
        return options
    }

    private func folderLabel(_ dir: String?) -> String {
        var label = model.folderName(dir) + (dir == nil ? " (padrão)" : "")
        if let summary = folders.summary(for: dir, environment: model.environment) {
            label += " · \(summary.conversationCount) conversas"
        }
        return label
    }

    private var folderLoginLabel: String {
        if case let .loggedIn(email?)? = model.folderStatus(draft.claudeConfigDir) { return "Login da própria pasta · \(email)" }
        return "Login da própria pasta"
    }

    private func slug(_ name: String) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
        let cleaned = folded.map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let text = String(cleaned).split(separator: "-").joined(separator: "-")
        return text.isEmpty ? "novo" : text
    }

    /// Providers with at least one key, plus OpenAI and Gemini (always shown, as in the design).
    private var providers: [APIProvider] {
        APIProvider.allCases.filter { provider in
            provider == .openai || provider == .gemini || model.config.apiKeys.contains { $0.provider == provider }
        }
    }

    private func keyBinding(_ provider: APIProvider) -> Binding<UUID?> {
        Binding(
            get: { draft.apiKeyIds.first { model.config.apiKey($0)?.provider == provider } },
            set: { draft = ConfigEditor.setAPIKey($0, for: provider, in: draft, config: model.config) }
        )
    }

    private func picker(_ title: String, symbol: String, selection: Binding<UUID?>, options: [(UUID, String, ProfileColor)]) -> some View {
        Picker(selection: selection) {
            Text("Nenhuma").tag(UUID?.none)
            ForEach(options, id: \.0) { option in
                Label {
                    Text(option.1)
                } icon: {
                    Image(systemName: "circle.fill").foregroundStyle(option.2.color)
                }
                .tag(UUID?.some(option.0))
            }
        } label: {
            Label(title, systemImage: symbol)
        }
    }

    private func load() { load(force: false) }

    private func load(force: Bool) {
        guard force || loadedFor != .some(profileId) else { return }
        loadedFor = .some(profileId)
        if let profileId, let existing = model.config.profile(profileId) {
            draft = existing
        } else {
            let color = ProfileColor.allCases[model.config.profiles.count % ProfileColor.allCases.count]
            draft = Profile(name: "", color: color, icon: .letter("?"))
        }
    }
}
