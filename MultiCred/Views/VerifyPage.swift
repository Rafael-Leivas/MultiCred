import MultiCredCore
import SwiftUI

/// "Verificar" (design 06): checklist of the active profile, each problem with
/// its fix; the fix's command is shown before anything runs.
struct VerifyPage: View {
    let model: AppModel
    let navigator: MainNavigator

    @State private var pendingFix: (CheckItem, Fix)?
    @State private var confirmFixAll = false
    @State private var running = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let report = model.verification {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        section("Ferramentas", report.items.filter { $0.section == .tools })
                        section("Integração", report.items.filter { $0.section == .integration })
                        section("Sessões", report.items.filter { $0.section == .sessions })
                    }
                    .padding(20)
                }
            } else if !model.isInstalled {
                ContentUnavailableView("MultiCred ainda não foi configurado", systemImage: "checklist")
                    .frame(maxHeight: .infinity)
            } else {
                ProgressView("Verificando…").frame(maxHeight: .infinity)
            }
            Divider()
            // Fixed footer, outside the scrolling list (the design screenshot overlaps it).
            HStack {
                Text("“Corrigir” mostra o comando antes de executar.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Verificar de novo") {
                    Task { await model.verify(checkTokens: true) }
                }
                .disabled(model.isVerifying)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .navigationTitle("Verificar")
        .task { await model.verify(checkTokens: true) }
        .alert(
            "Corrigir \(pendingFix?.0.title ?? "")?",
            isPresented: Binding(get: { pendingFix != nil }, set: { if !$0 { pendingFix = nil } }),
            presenting: pendingFix
        ) { item in
            Button("Executar") { Task { await run(item.1) } }
            Button("Cancelar", role: .cancel) {}
        } message: { item in
            Text(item.1.commandPreview(config: model.config, environment: model.environment, profileName: model.activeProfile?.name))
        }
        .alert("Corrigir tudo?", isPresented: $confirmFixAll) {
            Button("Executar") {
                Task {
                    running = true
                    let errors = await model.fixAll()
                    running = false
                    if let first = errors.first { model.lastError = first }
                }
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text(fixAllPreview)
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            if let profile = model.activeProfile {
                ProfileBadge(icon: profile.icon, color: profile.color, size: 44)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(model.activeProfile?.name ?? "Nenhum perfil ativo").font(.title2.weight(.semibold))
                if let report = model.verification {
                    Text("\(report.okCount) de \(report.checks.count) itens de acordo · verificado às \(report.checkedAt.formatted(date: .omitted, time: .shortened))")
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if model.isVerifying || running { ProgressView().controlSize(.small) }
            Button("Corrigir tudo") { confirmFixAll = true }
                .buttonStyle(.borderedProminent)
                .disabled(model.verification?.problems.contains { $0.fix != nil } != true || running)
        }
        .padding(20)
    }

    @ViewBuilder private func section(_ title: String, _ items: [CheckItem]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline).foregroundStyle(.secondary)
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { Divider() }
                        row(item)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))
            }
        }
    }

    private func row(_ item: CheckItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            StatusIcon24(status: item.status)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                if let expected = item.expected {
                    (Text("Esperado ") + Text(expected).bold() + Text(", encontrado \(item.detail ?? "nada")"))
                        .foregroundStyle(.secondary)
                } else if let detail = item.detail {
                    Text(detail).foregroundStyle(.secondary)
                }
                if let origin = item.origin {
                    Text("definido em \(origin)").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let fix = item.fix {
                Button(fixTitle(fix)) { pendingFix = (item, fix) }
                    .disabled(running)
            }
        }
        .padding(12)
    }

    private func fixTitle(_ fix: Fix) -> String {
        switch fix {
        case .loginClaude, .loginGitHub: "Entrar…"
        case .setAPIKeySecret: "Abrir chave…"
        default: "Corrigir"
        }
    }

    private var fixAllPreview: String {
        let fixes = (model.verification?.problems.compactMap(\.fix) ?? []).reduce(into: [Fix]()) { if !$0.contains($1) { $0.append($1) } }
        return fixes.map { "• " + $0.commandPreview(config: model.config, environment: model.environment, profileName: model.activeProfile?.name) }
            .joined(separator: "\n")
    }

    private func run(_ fix: Fix) async {
        running = true
        let result = await model.apply(fix)
        running = false
        switch result {
        case .done: break
        case let .failed(message): model.lastError = message
        case let .openClaudeToken(id): navigator.show(.claude, then: .replaceClaudeToken(id))
        case let .openClaudeFolderLogin(dir): navigator.showClaudeFolderLogin(dir)
        case let .openGitHubLogin(host): navigator.showGitHubLogin(host: host)
        case let .openAPIKey(id): navigator.show(.apiKeys, then: .editAPIKey(id))
        }
    }
}
