import MultiCredCore
import SwiftUI

/// Header of the menu bar menu (design 01a): active profile, status pill, the
/// three accounts, and an inline "Corrigir" when something is inconsistent.
/// Observes the model, so it updates while the menu is open.
struct MenuHeaderView: View {
    let model: AppModel
    let onVerify: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let profile = model.activeProfile {
                HStack(alignment: .top, spacing: 12) {
                    ProfileBadge(icon: profile.icon, color: profile.color, size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(profile.name).font(.headline)
                        if let since = model.state.activatedAt {
                            Text("Ativo desde \(since.formatted(date: .omitted, time: .shortened))").font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 8)
                    pill
                }
                VStack(alignment: .leading, spacing: 5) {
                    if let git = model.config.gitIdentity(profile.gitIdentityId) {
                        line("arrow.triangle.branch", git.email)
                    }
                    if let gh = model.config.githubAccount(profile.githubAccountId) {
                        line("chevron.left.forwardslash.chevron.right", gh.username)
                    }
                    line("sparkle", "Claude · \(model.folderName(profile.claudeConfigDir)) · \(model.claudeCredentialDescription(for: profile))"
                         + (model.state.claudeOverrideId != nil ? " (só Claude)" : ""))
                }
                .padding(.leading, 52)
            } else {
                Text("Nenhum perfil ativo").font(.headline)
                Text("Escolha um perfil abaixo.").foregroundStyle(.secondary)
            }
            if case let .problems(count, first) = model.consistency {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(first).font(.callout.weight(.medium)).lineLimit(2)
                        if count > 1 { Text("e mais \(count - 1)").font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    Button("Corrigir", action: onVerify)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.15)))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: 340, alignment: .leading)
    }

    @ViewBuilder private var pill: some View {
        switch model.consistency {
        case .ok: StatusPill(text: "Tudo certo", tone: .ok)
        case .problems: StatusPill(text: "Inconsistente", tone: .warning)
        case .unknown: StatusPill(text: model.isVerifying ? "Verificando" : "Não verificado", tone: .neutral)
        }
    }

    private func line(_ symbol: String, _ text: String) -> some View {
        Label {
            Text(text).lineLimit(1)
        } icon: {
            Image(systemName: symbol).frame(width: 16)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}
