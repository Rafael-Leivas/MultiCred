import AppKit
import MultiCredCore
import SwiftUI
import UserNotifications

/// HUD and notification after a switch (design 08). The short HUD fades after
/// 1.5 s; when Claude Code sessions are open with the previous account, the
/// HUD stays until "Ok" so the warning is not missed.
@MainActor
final class SwitchFeedbackPresenter {
    private var panel: NSPanel?
    private var dismissTask: Task<Void, Never>?
    private var askedForNotifications = false

    func present(_ outcome: SwitchOutcome, feedback: SwitchFeedback) {
        let claudeChanged = outcome.steps.contains(.launchd) || outcome.claudeOnly
        let warnSessions = claudeChanged && outcome.runningClaudeSessions > 0
        if feedback == .hud || (feedback != .none && warnSessions) {
            showHUD(outcome, sticky: warnSessions)
        }
        if feedback != .none {
            notify(outcome)
        }
    }

    // MARK: HUD

    private func showHUD(_ outcome: SwitchOutcome, sticky: Bool) {
        dismissTask?.cancel()
        panel?.orderOut(nil)

        let view = SwitchHUDView(outcome: outcome, sticky: sticky) { [weak self] in self?.dismiss() }
        let hosting = NSHostingView(rootView: view)
        hosting.frame.size = hosting.fittingSize
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: hosting.fittingSize), styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        panel.contentView = hosting
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = false
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.midY - panel.frame.height / 2))
        }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; panel.animator().alphaValue = 1 }
        self.panel = panel

        guard !sticky else { return }
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    private func dismiss() {
        guard let panel else { return }
        self.panel = nil
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; panel.animator().alphaValue = 0 }) {
            panel.orderOut(nil)
        }
    }

    // MARK: Notification

    private func notify(_ outcome: SwitchOutcome) {
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        if outcome.claudeOnly {
            content.title = "Conta Claude: \(outcome.claudeAccount?.nickname ?? "")"
            content.body = "Só o Claude Code mudou. Vale para novas sessões."
        } else {
            content.title = "Agora em \(outcome.profile?.name ?? "")"
            content.body = "\(SwitchHUDView.changedItems(outcome).joined(separator: ", ")) trocados."
        }
        let request = UNNotificationRequest(identifier: "switch", content: content, trigger: nil)
        Task {
            if !askedForNotifications {
                askedForNotifications = true
                _ = try? await center.requestAuthorization(options: [.alert])
            }
            try? await center.add(request)
        }
    }
}

struct SwitchHUDView: View {
    let outcome: SwitchOutcome
    let sticky: Bool
    let onClose: () -> Void

    static func changedItems(_ outcome: SwitchOutcome) -> [String] {
        var items: [String] = []
        if outcome.steps.contains(.git) { items.append("git") }
        if outcome.steps.contains(.github) { items.append("GitHub") }
        if outcome.steps.contains(.launchd) || outcome.claudeOnly { items.append("Claude") }
        return items.isEmpty ? ["Perfil"] : items
    }

    var body: some View {
        VStack(spacing: 14) {
            if outcome.claudeOnly, let account = outcome.claudeAccount {
                AccountAvatar(name: account.nickname, color: account.color, size: 64)
                Text(account.nickname).font(.title2.weight(.semibold))
            } else if let profile = outcome.profile {
                ProfileBadge(icon: profile.icon, color: profile.color, size: 64)
                Text(profile.name).font(.title2.weight(.semibold))
            }
            HStack(spacing: 14) {
                ForEach(Self.changedItems(outcome).map { $0 == "GitHub" ? "gh" : $0 }, id: \.self) { item in
                    Label(item, systemImage: "checkmark").foregroundStyle(.secondary)
                        .labelStyle(CheckLabelStyle())
                }
            }
            if sticky {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text("\(sessionsText) do Claude Code abertas antes da troca continuam na conta anterior. Reinicie-as para usar \(outcome.claudeAccount?.nickname ?? "a nova conta").")
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.15)))
                HStack {
                    Spacer()
                    Button("Ok", action: onClose).keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(28)
        .frame(width: sticky ? 400 : 240)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.regularMaterial))
        .accessibilityElement(children: .combine)
    }

    private var sessionsText: String {
        outcome.runningClaudeSessions == 1 ? "1 sessão" : "\(outcome.runningClaudeSessions) sessões"
    }
}

private struct CheckLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.foregroundStyle(.green).font(.caption.bold())
            configuration.title
        }
    }
}
