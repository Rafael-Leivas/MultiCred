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
                    picker("Claude", symbol: "sparkle", selection: $draft.claudeAccountId,
                           options: model.config.claudeAccounts.map { ($0.id, "\($0.nickname)\($0.email.map { " · \($0)" } ?? "")", $0.color) })
                    if draft.claudeAccountId == nil {
                        Label("Sem conta Claude, este perfil não troca o Claude: ele continua em \(model.appliedClaudeAccount?.nickname ?? "na conta atual").",
                              systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    ForEach(providers, id: \.self) { provider in
                        picker(provider.displayName, symbol: "key", selection: keyBinding(provider),
                               options: model.config.apiKeys.filter { $0.provider == provider }.map { ($0.id, "\($0.nickname) · \($0.envVar)", $0.color) })
                    }
                }
                Section {
                } footer: {
                    Text("“Nenhuma” deixa aquele item como está ao trocar para este perfil. Chaves de API ficam no Keychain do macOS; o perfil guarda só qual item usar.")
                }
            }
            .formStyle(.grouped)
            footer
        }
        .navigationTitle(isNew ? "Novo perfil" : "Editar perfil")
        .onAppear(perform: load)
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
