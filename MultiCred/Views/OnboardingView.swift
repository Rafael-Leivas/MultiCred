import MultiCredCore
import SwiftUI

/// Three-step onboarding (design 02b): Preparar → Perfis → Aplicar.
struct OnboardingView: View {
    let model: AppModel
    let onFinished: () -> Void

    private enum Step: Int, CaseIterable {
        case prepare, profiles, apply
        var title: String {
            switch self {
            case .prepare: "Preparar"
            case .profiles: "Perfis"
            case .apply: "Aplicar"
            }
        }
    }

    @State private var step: Step = .prepare
    @State private var setup: DetectedSetup?
    @State private var draft = Config()
    @State private var initialProfile: UUID?
    @State private var shells: Set<ShellKind> = []
    @State private var removeLegacy = true
    @State private var openAtLogin = true
    @State private var preview: Result<[FileChange], UserFacingError>?
    @State private var applying = false
    @State private var stepError: String?

    var body: some View {
        VStack(spacing: 0) {
            stepper.padding(.vertical, 12)
            Divider()
            Group {
                if let setup {
                    switch step {
                    case .prepare: prepare(setup)
                    case .profiles: profiles(setup)
                    case .apply: apply(setup)
                    }
                } else {
                    ProgressView("Procurando ferramentas e contas no seu Mac…").frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            footer.padding(16)
        }
        .task { await detect() }
    }

    // MARK: Chrome

    private var stepper: some View {
        HStack(spacing: 10) {
            ForEach(Step.allCases, id: \.self) { item in
                HStack(spacing: 6) {
                    ZStack {
                        Circle().fill(item.rawValue <= step.rawValue ? Color.accentColor : Color.primary.opacity(0.12)).frame(width: 20, height: 20)
                        if item.rawValue < step.rawValue {
                            Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                        } else {
                            Text("\(item.rawValue + 1)").font(.caption.bold()).foregroundStyle(item == step ? .white : .secondary)
                        }
                    }
                    Text(item.title).fontWeight(item == step ? .semibold : .regular).foregroundStyle(item == step ? .primary : .secondary)
                }
                if item != Step.allCases.last { Rectangle().fill(Color.primary.opacity(0.15)).frame(width: 30, height: 1) }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var footer: some View {
        HStack {
            if step == .prepare {
                Text("Dá para continuar sem o Claude Code e adicioná-lo depois.").font(.caption).foregroundStyle(.secondary)
            } else {
                Button("Voltar") { step = Step(rawValue: step.rawValue - 1)! }
            }
            if let stepError { Text(stepError).font(.caption).foregroundStyle(.red).lineLimit(2) }
            Spacer()
            switch step {
            case .prepare:
                Button("Continuar") { step = .profiles }.keyboardShortcut(.defaultAction).disabled(setup == nil)
            case .profiles:
                Button("Continuar") {
                    let issues = Validation.issues(in: draft)
                    if issues.isEmpty {
                        stepError = nil
                        step = .apply
                        refreshPreview()
                    } else {
                        stepError = UserMessages.describe(issues)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draft.profiles.isEmpty)
            case .apply:
                Button(applying ? "Aplicando…" : "Aplicar e começar") { Task { await finish() } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(applying || shells.isEmpty || (try? preview?.get()) == nil)
            }
        }
    }

    // MARK: Step 1

    private func prepare(_ setup: DetectedSetup) -> some View {
        HStack(alignment: .top, spacing: 32) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: -10) {
                    ProfileBadge(icon: .letter("P"), color: .orange, size: 44)
                    ProfileBadge(icon: .letter("N"), color: .indigo, size: 44)
                }
                Text("Bem-vindo ao MultiCred").font(.largeTitle.weight(.semibold))
                Text("Um clique na barra de menus troca, juntos, a identidade do git, a conta do GitHub CLI, a conta do Claude Code e as chaves de API dos terminais.")
                    .foregroundStyle(.secondary)
                Label("Nunca vê senhas ou tokens. O login é feito pelas próprias ferramentas.", systemImage: "lock")
                Label("Altera só um bloco marcado no fim de cada arquivo de shell e do gitconfig, com backup.", systemImage: "doc.text")
                Label("Pode desinstalar e restaurar tudo a qualquer momento.", systemImage: "arrow.uturn.backward")
            }
            .frame(maxWidth: 360, alignment: .leading)

            VStack(alignment: .leading, spacing: 10) {
                Text("Ferramentas no seu Mac").font(.headline)
                VStack(spacing: 0) {
                    ForEach(Array(setup.tools.enumerated()), id: \.offset) { index, info in
                        if index > 0 { Divider() }
                        toolRow(info)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
                Button("Verificar de novo") { Task { await detect(keepDraft: true) } }
            }
            .frame(maxWidth: 420)
        }
        .padding(28)
    }

    private func toolRow(_ info: DetectedSetup.ToolInfo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading) {
                    Text(info.tool.displayName).fontWeight(.medium)
                    Text(info.version ?? (info.path == nil ? "Não encontrado" : info.path!))
                        .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                }
                Spacer()
                StatusPill(text: info.path == nil ? "Faltando" : "Instalado", tone: info.path == nil ? .warning : .ok)
            }
            if info.path == nil {
                HStack {
                    Text(installCommand(info.tool)).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    Spacer()
                    Button("Copiar") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(installCommand(info.tool), forType: .string)
                    }
                    .controlSize(.small)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
            }
        }
        .padding(12)
    }

    private func installCommand(_ tool: Tool) -> String {
        switch tool {
        case .git: "xcode-select --install"
        case .gh: "brew install gh"
        case .claude: "curl -fsSL https://claude.ai/install.sh | bash"
        }
    }

    // MARK: Step 2

    private func profiles(_ setup: DetectedSetup) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Perfis sugeridos").font(.title2.weight(.semibold))
                Text("Montados a partir do que já existe no seu Mac: \(setup.gitEmail == nil ? 0 : 1) identidade git, \(setup.githubLogins.count) conta(s) GitHub e \(setup.claudeFolders.count) conta(s) Claude. Dá para ajustar tudo depois.")
                    .foregroundStyle(.secondary)
                if setup.hasLegacyInstall {
                    InfoNote(text: "Encontramos a versão antiga em ~/Perfis. Os perfis abaixo vieram do perfis.conf, e no próximo passo você pode remover as linhas antigas do seu ~/.zshrc e ~/.gitconfig.", symbol: "clock.arrow.circlepath")
                }
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)], spacing: 16) {
                    ForEach($draft.profiles) { $profile in
                        ProfileSuggestionCard(profile: $profile, config: $draft, statuses: claudeStatuses(setup)) {
                            draft.profiles.removeAll { $0.id == profile.id }
                        }
                    }
                }
                Button {
                    let color = ProfileColor.allCases[draft.profiles.count % ProfileColor.allCases.count]
                    draft.profiles.append(Profile(name: "Novo perfil", color: color))
                } label: { Label("Adicionar perfil", systemImage: "plus") }
            }
            .padding(24)
        }
    }

    private func claudeStatuses(_ setup: DetectedSetup) -> [String?: ClaudeLoginStatus] {
        Dictionary(setup.claudeFolders.compactMap { folder in folder.status.map { (folder.configDir, $0) } }, uniquingKeysWith: { a, _ in a })
    }

    // MARK: Step 3

    private func apply(_ setup: DetectedSetup) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Revise antes de aplicar").font(.title2.weight(.semibold))
                Text("Estas são as únicas mudanças fora da pasta ~/Library/Application Support/MultiCred.").foregroundStyle(.secondary)

                GroupBox("Shells que vão carregar o MultiCred") {
                    HStack(spacing: 20) {
                        ForEach(ShellKind.allCases, id: \.self) { shell in
                            Toggle(shell.rawValue + (model.environment.loginShell.hasSuffix("/" + shell.rawValue) ? " (seu shell)" : ""), isOn: Binding(
                                get: { shells.contains(shell) },
                                set: { enabled in
                                    if enabled { shells.insert(shell) } else { shells.remove(shell) }
                                    refreshPreview()
                                }
                            ))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }
                if !setup.legacyFindings.isEmpty {
                    Toggle("Remover as linhas da versão antiga (~/Perfis), que brigariam com o MultiCred", isOn: Binding(
                        get: { removeLegacy },
                        set: { removeLegacy = $0; refreshPreview() }
                    ))
                }

                switch preview {
                case let .success(changes)?:
                    ForEach(changes) { FileChangeView(change: $0) }
                case let .failure(message)?:
                    Label(message.text, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                case nil:
                    ProgressView()
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Backup dos originais em ~/Library/Application Support/MultiCred/backups/", systemImage: "archivebox")
                        Picker(selection: $initialProfile) {
                            ForEach(draft.profiles) { profile in
                                Text(profile.name).tag(UUID?.some(profile.id))
                            }
                        } label: {
                            Label("Perfil inicial", systemImage: "arrow.triangle.2.circlepath")
                        }
                        Toggle(isOn: $openAtLogin) { Label("Abrir ao iniciar a sessão", systemImage: "clock") }
                    }
                    .padding(4)
                }
                Text("Abra um novo Terminal depois de aplicar para que o shell carregue o perfil. Apps gráficos (VS Code etc.) pegam a conta do Claude ao serem reabertos.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(24)
        }
    }

    private func refreshPreview() {
        preview = model.previewInstall(InstallOptions(shells: ShellKind.allCases.filter(shells.contains), removeLegacy: removeLegacy))
    }

    // MARK: Actions

    private func detect(keepDraft: Bool = false) async {
        let found = await model.detectSetup()
        setup = found
        guard !keepDraft || draft.profiles.isEmpty else { return }
        let (config, initial) = SetupDetector.suggestedConfig(from: found, environment: model.environment)
        draft = config
        initialProfile = initial
        removeLegacy = !found.legacyFindings.isEmpty
        var defaults: Set<ShellKind> = []
        for shell in ShellKind.allCases {
            let isLoginShell = model.environment.loginShell.hasSuffix("/" + shell.rawValue)
            let hasRC = Integrations.rcFiles(for: shell, environment: model.environment).contains { FileManager.default.fileExists(atPath: $0.path) }
            if isLoginShell || hasRC { defaults.insert(shell) }
        }
        shells = defaults.isEmpty ? [.zsh] : defaults
    }

    private func finish() async {
        applying = true
        defer { applying = false }
        let options = InstallOptions(shells: ShellKind.allCases.filter(shells.contains), removeLegacy: removeLegacy)
        if let error = await model.completeOnboarding(config: draft, options: options, initialProfile: initialProfile, openAtLogin: openAtLogin) {
            stepError = error
            return
        }
        onFinished()
    }
}

/// One editable suggested profile (design 02b, step 2).
private struct ProfileSuggestionCard: View {
    @Binding var profile: Profile
    @Binding var config: Config
    let statuses: [String?: ClaudeLoginStatus]
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                ProfileBadge(icon: .letter(String(profile.name.prefix(1))), color: profile.color, size: 26)
                TextField("Nome", text: Binding(get: { profile.name }, set: {
                    profile.name = $0
                    profile.icon = .letter(String($0.prefix(1)).uppercased())
                }))
                .textFieldStyle(.plain)
                .font(.headline)
                Spacer()
                let missing = missingCount
                StatusPill(text: missing == 0 ? "Completo" : "Falta \(missing) item", tone: missing == 0 ? .ok : .warning)
                Button(action: onRemove) { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(.secondary)
                    .accessibilityLabel("Remover perfil")
            }
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("git").foregroundStyle(.secondary)
                    HStack {
                        TextField("Nome", text: gitBinding(\.name))
                        TextField("e-mail", text: gitBinding(\.email))
                    }
                }
                GridRow {
                    Text("GitHub").foregroundStyle(.secondary)
                    Picker("", selection: $profile.githubAccountId) {
                        Text("Não trocar").tag(UUID?.none)
                        ForEach(config.githubAccounts) { Text($0.username).tag(UUID?.some($0.id)) }
                    }
                    .labelsHidden()
                }
                GridRow {
                    Text("Claude").foregroundStyle(.secondary)
                    Picker("", selection: $profile.claudeAccountId) {
                        Text("Não trocar").tag(UUID?.none)
                        ForEach(config.claudeAccounts) { account in
                            Text(claudeLabel(account)).tag(UUID?.some(account.id))
                        }
                    }
                    .labelsHidden()
                }
            }
            .font(.callout)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08)))
    }

    private var missingCount: Int {
        [profile.gitIdentityId == nil, profile.githubAccountId == nil, profile.claudeAccountId == nil].filter { $0 }.count
    }

    private func claudeLabel(_ account: ClaudeAccount) -> String {
        let folder = account.configDir.map { URL(fileURLWithPath: $0).lastPathComponent } ?? ".claude"
        let state = statuses[account.configDir].map { $0.isLoggedIn ? "" : " · entrar depois" } ?? ""
        return "\(account.email ?? account.nickname) (\(folder))\(state)"
    }

    /// Edits the profile's git identity, creating one on first edit.
    private func gitBinding(_ keyPath: WritableKeyPath<GitIdentity, String>) -> Binding<String> {
        Binding(
            get: { config.gitIdentity(profile.gitIdentityId)?[keyPath: keyPath] ?? "" },
            set: { value in
                if let index = config.gitIdentities.firstIndex(where: { $0.id == profile.gitIdentityId }) {
                    config.gitIdentities[index][keyPath: keyPath] = value
                } else {
                    var identity = GitIdentity(nickname: profile.name, name: "", email: "", color: profile.color)
                    identity[keyPath: keyPath] = value
                    config.gitIdentities.append(identity)
                    profile.gitIdentityId = identity.id
                }
            }
        )
    }
}
