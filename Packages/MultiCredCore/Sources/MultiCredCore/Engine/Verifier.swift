import Foundation

/// A repair the user can run from the Verify screen. `commandPreview` is what
/// the screen shows before anything runs ("Corrigir mostra o comando antes").
public enum Fix: Equatable, Sendable {
    case reapplyProfile
    case reinstallIntegration
    case removeLegacy
    case switchGitHub(host: String, user: String)
    case loginClaude(UUID)
    case loginGitHub(host: String)
    case setAPIKeySecret(UUID)
}

public struct CheckItem: Identifiable, Equatable, Sendable {
    public enum Section: String, Sendable { case tools, integration, sessions }
    public enum Status: Sendable { case ok, warning, error, info }

    public let id: String
    public let section: Section
    public let title: String
    public let status: Status
    /// Value found, or a short explanation.
    public let detail: String?
    public let expected: String?
    /// Where the found value comes from (git: file).
    public let origin: String?
    public let fix: Fix?
}

public struct VerificationReport: Equatable, Sendable {
    public let items: [CheckItem]
    public let checkedAt: Date

    public var problems: [CheckItem] { items.filter { $0.status == .error } }
    public var isConsistent: Bool { problems.isEmpty }
    public var checks: [CheckItem] { items.filter { $0.status != .info } }
    public var okCount: Int { checks.filter { $0.status == .ok }.count }
}

/// Compares the real state of git, gh, launchd, the shells and the Keychain
/// with what the active profile expects (design 06). Read-only.
public struct Verifier: Sendable {
    let environment: SystemEnvironment
    let tools: any ToolLocating
    let processes: any ProcessScanning
    let paths: AppPaths

    public init(environment: SystemEnvironment, tools: any ToolLocating, processes: any ProcessScanning) {
        self.environment = environment
        self.tools = tools
        self.processes = processes
        paths = AppPaths(environment: environment)
    }

    /// - Parameters:
    ///   - checkGitHubTokens: also ask gh whether the token works (network, slow).
    ///   - claudeStatus: login status of a Claude account (cached by the app).
    public func run(
        config: Config,
        state: ActiveState,
        checkGitHubTokens: Bool,
        claudeStatus: @Sendable (ClaudeAccount) async -> ClaudeLoginStatus
    ) async -> VerificationReport {
        var items: [CheckItem] = []
        let env = environment.baseProcessEnvironment(path: await tools.searchDirectories())
        let profile = config.profile(state.profileId)

        // Tools: git identity.
        if let identity = config.gitIdentity(profile?.gitIdentityId), let git = await tools.locate(.git) {
            for (key, expected, title) in [("user.name", identity.name, "git · user.name"), ("user.email", identity.email, "git · user.email")] {
                let (value, origin) = await gitValue(key, git: git, env: env)
                let ok = value == expected
                let fromOurFile = origin.map { $0.hasSuffix(paths.gitconfig.path) } ?? false
                items.append(CheckItem(
                    id: "git.\(key)", section: .tools, title: title,
                    status: ok ? .ok : .error,
                    detail: value ?? "não definido",
                    expected: ok ? nil : expected,
                    origin: ok ? nil : origin.map(environment.abbreviate),
                    fix: ok ? nil : (fromOurFile || value == nil ? .reapplyProfile : .reinstallIntegration)
                ))
            }
        }

        // Tools: GitHub CLI.
        if let account = config.githubAccount(profile?.githubAccountId) {
            if let gh = await tools.locate(.gh) {
                let cli = GitHubCLI(runner: environment.runner, executable: gh, baseEnvironment: env)
                let active = try? await cli.activeLogin(host: account.host)
                let ok = active?.caseInsensitiveCompare(account.username) == .orderedSame
                items.append(CheckItem(
                    id: "gh.active", section: .tools, title: "GitHub CLI · conta ativa",
                    status: ok ? .ok : .error,
                    detail: active.map { "\($0) em \(account.host)" } ?? "nenhuma conta ativa",
                    expected: ok ? nil : account.username, origin: nil,
                    fix: ok ? nil : .switchGitHub(host: account.host, user: account.username)
                ))
                if checkGitHubTokens, let logins = try? await cli.logins() {
                    let login = logins.first { $0.host == account.host && $0.login.caseInsensitiveCompare(account.username) == .orderedSame }
                    let usable = login?.isUsable == true
                    items.append(CheckItem(
                        id: "gh.token", section: .tools, title: "GitHub CLI · login de \(account.username)",
                        status: usable ? .ok : .warning,
                        detail: usable ? "token válido" : (login == nil ? "conta não está no gh" : "o gh precisa de um novo login"),
                        expected: nil, origin: nil,
                        fix: usable ? nil : .loginGitHub(host: account.host)
                    ))
                }
            } else {
                items.append(CheckItem(id: "gh.missing", section: .tools, title: "GitHub CLI", status: .error, detail: "gh não encontrado", expected: nil, origin: nil, fix: nil))
            }
        }

        // Tools: Claude Code.
        if let account = config.claudeAccount(state.appliedClaudeAccountId) {
            let launchd = try? await Launchctl(runner: environment.runner, baseEnvironment: env).getenv(SwitchEngine.claudeVariable)
            let ok = launchd == account.configDir
            items.append(CheckItem(
                id: "claude.launchd", section: .tools, title: "Claude Code · conta para apps",
                status: ok ? .ok : .error,
                detail: launchd.map(environment.abbreviate) ?? "~/.claude (padrão)",
                expected: ok ? nil : (account.configDir.map(environment.abbreviate) ?? "~/.claude (padrão)"),
                origin: ok ? nil : "launchctl", fix: ok ? nil : .reapplyProfile
            ))
            let status = await claudeStatus(account)
            let email = account.email.map { " · \($0)" } ?? ""
            items.append(CheckItem(
                id: "claude.login", section: .tools, title: "Claude Code · conta",
                status: status.isLoggedIn ? .ok : (status == .loggedOut ? .error : .warning),
                detail: status.isLoggedIn ? "\(account.nickname)\(email)" : (status == .loggedOut ? "\(account.nickname) precisa entrar" : "status indisponível"),
                expected: nil, origin: nil,
                fix: status == .loggedOut ? .loginClaude(account.id) : nil
            ))
        }

        // Tools: API keys of the profile.
        for keyId in profile?.apiKeyIds ?? [] {
            guard let key = config.apiKey(keyId) else { continue }
            let present = (try? environment.keychain.containsItem(account: key.keychainAccount)) ?? false
            items.append(CheckItem(
                id: "key.\(keyId)", section: .tools, title: "\(key.provider.displayName) · \(key.envVar)",
                status: present ? .ok : .error,
                detail: present ? "\(key.nickname) no Keychain" : "chave não está no Keychain",
                expected: nil, origin: nil, fix: present ? nil : .setAPIKeySecret(keyId)
            ))
        }

        // Integration.
        if let manifest = Installer(environment: environment).manifest() {
            for shell in manifest.shells {
                let files = Integrations.rcFiles(for: shell, environment: environment)
                let blocks = files.allSatisfy { file in
                    (try? String(contentsOf: (try? AtomicFileWriter.resolveTarget(file, followSymlink: true)) ?? file, encoding: .utf8)).map(ManagedBlock.contains) ?? false
                }
                let fishOK = shell != .fish || ((try? String(contentsOf: Integrations.fishConfFile(environment: environment), encoding: .utf8)).map(ManagedBlock.contains) ?? false)
                let hookOK = (try? String(contentsOf: paths.hook(shell), encoding: .utf8)) == ShellHookRenderer.render(shell)
                let ok = blocks && fishOK && hookOK
                let names = shell == .fish ? "~/.config/fish/conf.d" : files.map { environment.abbreviate($0.path) }.joined(separator: " e ")
                items.append(CheckItem(
                    id: "shell.\(shell.rawValue)", section: .integration, title: "\(names) carrega o MultiCred",
                    status: ok ? .ok : .error,
                    detail: ok ? nil : (hookOK ? "a linha do MultiCred foi removida" : "o arquivo do hook está diferente"),
                    expected: nil, origin: nil, fix: ok ? nil : .reinstallIntegration
                ))
            }
            let gitFile = Integrations.globalGitConfig(environment: environment)
            let gitText = (try? String(contentsOf: (try? AtomicFileWriter.resolveTarget(gitFile, followSymlink: true)) ?? gitFile, encoding: .utf8)) ?? ""
            let gitOK = ManagedBlock.contains(gitText) && ManagedBlock.isLast(in: gitText)
            items.append(CheckItem(
                id: "git.include", section: .integration, title: "\(environment.abbreviate(gitFile.path)) inclui o MultiCred por último",
                status: gitOK ? .ok : .error,
                detail: gitOK ? nil : (ManagedBlock.contains(gitText) ? "há configurações depois do include" : "o include foi removido"),
                expected: nil, origin: nil, fix: gitOK ? nil : .reinstallIntegration
            ))
            let envOK = (try? String(contentsOf: paths.envSh, encoding: .utf8))?.hasPrefix("# Generated by MultiCred. Do not edit. generation=\(state.generation)\n") ?? (state.generation == 0)
            items.append(CheckItem(
                id: "env.files", section: .integration, title: "Arquivos de ambiente do shell",
                status: envOK ? .ok : .error,
                detail: envOK ? nil : "desatualizados em relação ao perfil ativo",
                expected: nil, origin: nil, fix: envOK ? nil : .reapplyProfile
            ))
        }
        let legacy = LegacyMigration.findings(environment: environment)
        if !legacy.isEmpty {
            items.append(CheckItem(
                id: "legacy", section: .integration, title: "Versão antiga (~/Perfis) ainda ativa",
                status: .error,
                detail: legacy.map { environment.abbreviate($0.file.path) }.joined(separator: ", "),
                expected: nil, origin: nil, fix: .removeLegacy
            ))
        }

        // Sessions.
        let sessions = processes.claudeCodeSessionCount()
        if sessions > 0 {
            items.append(CheckItem(
                id: "claude.sessions", section: .sessions,
                title: sessions == 1 ? "1 sessão do Claude Code aberta" : "\(sessions) sessões do Claude Code abertas",
                status: .info,
                detail: "Sessões abertas antes da última troca continuam na conta em que foram abertas até serem reiniciadas.",
                expected: nil, origin: nil, fix: nil
            ))
        }
        return VerificationReport(items: items, checkedAt: environment.clock())
    }

    /// Effective value as `git commit` sees it, and the file it comes from.
    private func gitValue(_ key: String, git: URL, env: [String: String]) async -> (String?, String?) {
        let result = try? await environment.runner.run(CommandRequest(
            executable: git,
            arguments: ["config", "--includes", "--show-origin", "--get", key],
            environment: env,
            currentDirectory: environment.home,
            timeout: .seconds(10)
        ))
        guard let result, result.succeeded else { return (nil, nil) }
        let line = result.stdout.trimmingCharacters(in: .newlines)
        guard let tab = line.firstIndex(of: "\t") else { return (line, nil) }
        var origin = String(line[..<tab])
        if origin.hasPrefix("file:") { origin.removeFirst(5) }
        return (String(line[line.index(after: tab)...]), origin)
    }
}

extension Fix {
    /// What the Verify screen shows before running the repair.
    public func commandPreview(config: Config, environment: SystemEnvironment, profileName: String?) -> String {
        switch self {
        case .reapplyProfile:
            "Reaplicar o perfil \(profileName ?? "ativo"): reescreve o gitconfig incluído, a conta do gh, CLAUDE_CONFIG_DIR (launchctl) e os arquivos de ambiente do shell."
        case .reinstallIntegration:
            "Reescrever o bloco do MultiCred no fim de ~/.zshrc, ~/.bash_profile, ~/.bashrc e do gitconfig global (com backup)."
        case .removeLegacy:
            "Remover as linhas da versão antiga (~/Perfis) dos arquivos de shell e do gitconfig global (com backup)."
        case let .switchGitHub(host, user):
            "gh auth switch --hostname \(host) --user \(user)"
        case let .loginClaude(id):
            "Abrir o login da conta Claude \(config.claudeAccount(id)?.nickname ?? "")."
        case let .loginGitHub(host):
            "gh auth login --hostname \(host) --git-protocol https --web"
        case let .setAPIKeySecret(id):
            "Abrir a chave \(config.apiKey(id)?.nickname ?? "") para colar o valor de novo."
        }
    }
}
