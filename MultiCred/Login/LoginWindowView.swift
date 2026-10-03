import MultiCredCore
import SwiftUI

/// "Entrar no Claude" page (design 05b, terminal variation, output collapsible),
/// shown inside the Accounts window. Back, Cancel and Done return to the list.
struct LoginPage: View {
    @Bindable var session: LoginSession
    let model: AppModel
    let navigator: AccountsNavigator

    @State private var code = ""
    @State private var showOutput = false
    @State private var activationError: String?

    private var account: ClaudeAccount { session.account }
    private var isOutputVisible: Bool { showOutput || session.phase.isFailure }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if model.isTestMode {
                Label("Simulação do modo de teste: o navegador não abre. Digite qualquer código para conectar, ou \"erro\" para ver a tela de erro.", systemImage: "testtube.2")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(message)
                .font(.callout)
                .foregroundStyle(session.phase.isFailure ? .red : .secondary)
                .fixedSize(horizontal: false, vertical: true)

            if isOutputVisible {
                TerminalOutput(
                    directory: model.environment.abbreviate(ClaudePaths.effectiveDirectory(of: account, environment: model.environment)),
                    command: model.isTestMode ? "claude auth login (simulado)" : "claude auth login",
                    text: session.output
                )
            }

            if session.phase == .connected {
                Label("Credenciais guardadas pelo Claude Code. O MultiCred não as armazena.", systemImage: "lock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                codeRow
            }
            if let activationError {
                Text(activationError).font(.caption).foregroundStyle(.red)
            }
            Spacer(minLength: 0)
            footer
        }
        .padding(20)
        .navigationTitle("Entrar no Claude")
    }

    private var header: some View {
        HStack(spacing: 12) {
            AccountAvatar(name: account.nickname, color: account.color, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(account.nickname).font(.headline)
                Text(account.email ?? model.environment.abbreviate(ClaudePaths.effectiveDirectory(of: account, environment: model.environment)))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            StatusPill(text: session.phase.title, tone: session.phase.tone)
        }
    }

    private var codeRow: some View {
        HStack {
            Text("Código").foregroundStyle(.secondary)
            SecureField("Cole o código de autorização", text: $code)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .onSubmit(sendCode)
                .disabled(session.phase.isFinished)
            if session.phase.isFailure {
                Button("Tentar de novo") { navigator.showLogin(account, replacingTop: true) }
            } else {
                Button("Conectar", action: sendCode)
                    .keyboardShortcut(.defaultAction)
                    .disabled(code.trimmingCharacters(in: .whitespaces).isEmpty || !session.phase.acceptsCode)
            }
        }
    }

    private var footer: some View {
        HStack {
            if session.phase.isFailure {
                Button("Copiar log") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(session.redactedLog, forType: .string)
                }
                .buttonStyle(.link)
            } else {
                Button {
                    showOutput.toggle()
                } label: {
                    Label(showOutput ? "Ocultar saída" : "Mostrar saída", systemImage: showOutput ? "chevron.down" : "chevron.right")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            Spacer()
            switch session.phase {
            case .connected:
                Button("Ativar \(account.nickname)") {
                    Task {
                        activationError = await model.switchClaudeOnly(to: account.id)
                        if activationError == nil { navigator.reset() }
                    }
                }
                Button("Concluir") { navigator.reset() }.keyboardShortcut(.defaultAction)
            case .failed:
                Button("Voltar") { navigator.back() }
                if canOpenBrowser {
                    Button("Abrir navegador de novo") { session.openBrowserAgain() }.keyboardShortcut(.defaultAction)
                }
            default:
                if canOpenBrowser {
                    Button("Abrir navegador de novo") { session.openBrowserAgain() }
                        .disabled(session.authorizationURL == nil)
                }
                Button("Cancelar") {
                    session.cancel()
                    navigator.back()
                }
            }
        }
    }

    /// The simulator's URL is fake; only the real CLI gives one worth opening.
    private var canOpenBrowser: Bool { !model.isTestMode }

    private var message: String {
        switch session.phase {
        case .starting, .waitingForBrowser:
            "O navegador vai abrir para você autorizar o Claude Code nesta conta."
        case .waitingForCode:
            "Autorize no navegador. Se ele mostrar um código, cole abaixo; se a página disser que deu certo, é só aguardar."
        case .connecting:
            "Conectando ao Claude…"
        case .connected:
            "Pronto. Os perfis que usam \(account.nickname) já podem usar esta conta."
        case let .failed(reason):
            session.launchError ?? "Não deu certo (\(reason)). O código vale por poucos minutos: gere outro no navegador e tente de novo."
        }
    }

    private func sendCode() {
        session.submit(code: code)
        code = ""
    }
}

extension LoginPhase {
    var title: String {
        switch self {
        case .starting, .waitingForBrowser: "Aguardando navegador"
        case .waitingForCode: "Aguardando código"
        case .connecting: "Conectando"
        case .connected: "Conectada"
        case .failed: "Erro"
        }
    }

    var tone: PillTone {
        switch self {
        case .connected: .ok
        case .failed: .error
        default: .warning
        }
    }

    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }

    var acceptsCode: Bool {
        self == .waitingForCode || self == .waitingForBrowser
    }
}

/// Dark, monospaced output panel (design 05b), following the newest line.
struct TerminalOutput: View {
    let directory: String
    let command: String
    let text: String

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    Text(directory).foregroundStyle(.gray)
                    (Text("$ ").foregroundStyle(.blue) + Text(command))
                    Text(text.replacingOccurrences(of: "\r", with: ""))
                        .textSelection(.enabled)
                    Color.clear.frame(height: 1).id("end")
                }
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Color(white: 0.92))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
            .onChange(of: text) { proxy.scrollTo("end", anchor: .bottom) }
        }
        .frame(height: 190)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(white: 0.08)))
        .accessibilityLabel("Saída do Claude Code")
    }
}
