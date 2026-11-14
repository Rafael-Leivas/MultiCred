import Foundation
import MultiCredCore

/// Builds the "is my MultiCred right?" report from the same `Verifier` the
/// Verify screen uses, on a read-only environment. Never mentions a secret:
/// it has none (the environment cannot read them).
public struct DiagnosticService: Sendable {
    let environment: SystemEnvironment
    let tools: any ToolLocating
    let processes: any ProcessScanning
    let guide: Guide

    public init(environment: SystemEnvironment, tools: any ToolLocating, processes: any ProcessScanning, guide: Guide) {
        self.environment = environment
        self.tools = tools
        self.processes = processes
        self.guide = guide
    }

    public func report() async -> String {
        let paths = AppPaths(environment: environment)
        let config: Config
        do {
            guard let loaded = try ConfigRepository(environment: environment).loadReadOnly() else {
                return """
                # Diagnóstico do MultiCred (somente leitura)
                MultiCred ainda não configurado neste Mac (não existe \(environment.abbreviate(paths.config.path))). \
                Abra o app e use "Configurar MultiCred…" no menu da barra para fazer o onboarding.\(environment.mode == .real ? "" : "\n(Este ajudante está em modo de teste e olhou o sandbox, não o seu Mac real.)")
                """
            }
            config = loaded
        } catch {
            // The raw error can quote file contents; it stays out of what the model sees.
            return "# Diagnóstico do MultiCred (somente leitura)\nNão consegui ler \(environment.abbreviate(paths.config.path)): o arquivo está ilegível ou é de uma versão mais nova do app. Abra o MultiCred e confira Ajustes › Copiar diagnóstico."
        }
        let state = (try? StateStore(paths: paths).load()) ?? ActiveState()
        let searchPath = await tools.searchDirectories()
        let environment = self.environment, tools = self.tools
        let processEnvironment = environment.baseProcessEnvironment(path: searchPath)

        var lines = ["# Diagnóstico do MultiCred (somente leitura)", "MultiCred \(guide.version) · modo \(environment.mode.rawValue)"]
        lines.append(describeProfile(config.profile(state.profileId), config: config))
        lines.append("")
        lines.append("Ferramentas:")
        let toolLines = await withTaskGroup(of: (Int, String).self) { group in
            for (index, tool) in Tool.allCases.enumerated() {
                group.addTask {
                    guard let url = await tools.locate(tool) else { return (index, "- \(tool.displayName): não encontrado") }
                    let result = try? await environment.runner.run(CommandRequest(executable: url, arguments: ["--version"], environment: processEnvironment, timeout: .seconds(10)))
                    let version = result.flatMap { $0.succeeded ? $0.stdout.split(whereSeparator: \.isNewline).first.map(String.init) : nil } ?? "versão desconhecida"
                    return (index, "- \(tool.displayName): \(version) (\(url.path))")
                }
            }
            var found: [(Int, String)] = []
            for await item in group { found.append(item) }
            return found.sorted { $0.0 < $1.0 }.map(\.1)
        }
        lines += toolLines

        let claude = await tools.locate(.claude).map {
            ClaudeCLI(runner: environment.runner, executable: $0, baseEnvironment: processEnvironment)
        }
        let verifier = Verifier(environment: environment, tools: tools, processes: processes)
        let verification = await verifier.run(config: config, state: state, checkGitHubTokens: false) { account in
            guard let claude else { return .unknown("Claude Code não encontrado") }
            return await claude.authStatus(for: account)
        }

        let problems = verification.items.filter { $0.status == .error }
        let warnings = verification.items.filter { $0.status == .warning }
        lines.append("")
        lines.append(problems.isEmpty && warnings.isEmpty
            ? "Nenhum problema encontrado: \(verification.okCount) de \(verification.checks.count) verificações ok."
            : "\(problems.count) problema(s) e \(warnings.count) aviso(s) em \(verification.checks.count) verificações.")

        let profileName = config.profile(state.profileId)?.name
        for (heading, tag, items) in [("Problemas", "ERRO", problems), ("Avisos", "ATENÇÃO", warnings)] where !items.isEmpty {
            lines.append("")
            lines.append("## \(heading)")
            for item in items {
                lines.append("- [\(tag)] \(item.title)\(item.detail.map { ": \($0)" } ?? "")\(item.expected.map { " (esperado: \($0))" } ?? "")\(item.origin.map { " [origem: \($0)]" } ?? "")")
                if let fix = item.fix {
                    lines.append("  No app: abra Verificar › \"Corrigir\". \(fix.commandPreview(config: config, environment: environment, profileName: profileName))")
                    if let hint = guideHint(for: fix) { lines.append("  Ajuda: \(hint)") }
                }
            }
        }
        let healthy = verification.items.filter { $0.status == .ok }
        if !healthy.isEmpty {
            lines.append("")
            lines.append("## Tudo certo")
            lines += healthy.map { "- [OK] \($0.title)\($0.detail.map { ": \($0)" } ?? "")" }
        }
        let info = verification.items.filter { $0.status == .info }
        if !info.isEmpty {
            lines.append("")
            lines.append("## Informação")
            lines += info.map { "- \($0.title)\($0.detail.map { ": \($0)" } ?? "")" }
        }
        lines.append("")
        lines.append("Perfis configurados: " + (config.profiles.isEmpty ? "nenhum" : config.profiles.map(\.name).joined(separator: ", ")))
        lines.append("Contas Claude (token/login): " + (config.claudeAccounts.isEmpty ? "nenhuma" : config.claudeAccounts.map { "\($0.nickname) (\($0.kind == .login ? "login" : "token"))" }.joined(separator: ", ")))
        lines.append("Este diagnóstico só leu o estado; nada foi alterado. Para corrigir, use o botão do app indicado acima.")
        return lines.joined(separator: "\n")
    }

    private func describeProfile(_ profile: Profile?, config: Config) -> String {
        guard let profile else { return "Perfil ativo: nenhum (ative um perfil no menu da barra)." }
        var parts = ["Perfil ativo: \(profile.name)"]
        if let git = config.gitIdentity(profile.gitIdentityId) { parts.append("git \(git.name) <\(git.email)>") }
        if let gh = config.githubAccount(profile.githubAccountId) { parts.append("GitHub \(gh.username)@\(gh.host)") }
        parts.append("pasta Claude " + (profile.claudeConfigDir.map(environment.abbreviate) ?? "~/.claude (padrão)"))
        let keys = profile.apiKeyIds.compactMap { config.apiKey($0)?.envVar }
        if !keys.isEmpty { parts.append("chaves: " + keys.joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }

    /// The guide entry that explains a failed check, as a hint for the model.
    private func guideHint(for fix: Fix) -> String? {
        func problem(_ id: String) -> String? {
            guide.problems.first { $0.id == id }.map { "solucao_de_problemas (\($0.id)): \($0.title)" }
        }
        func task(_ id: String) -> String? {
            guide.tasks.first { $0.id == id }.map { "como_fazer (\($0.id)): \($0.title)" }
        }
        switch fix {
        case .reapplyProfile, .reinstallIntegration, .removeLegacy: return problem("terminal-nao-trocou")
        case .switchGitHub, .loginGitHub: return problem("gh-conta-errada")
        case .loginClaude, .loginClaudeFolder: return problem("login-claude-falhou")
        case .setAPIKeySecret: return task("chaves-de-api")
        }
    }
}
