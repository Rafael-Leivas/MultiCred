import MultiCredCore
import SwiftUI

/// "Entrar no Claude" page for a Claude folder's own login (design 05b, terminal
/// variation, output collapsible). Back, Cancel and Done return to the list.
struct LoginPage: View {
    @Bindable var session: LoginSession
    let model: AppModel
    let navigator: MainNavigator

    @State private var code = ""
    @State private var showOutput = false
    @State private var activationError: String?
    @State private var openedURL: URL?
    @AppStorage(BrowserChoice.storageKey) private var browserChoice = ""

    private var account: ClaudeAccount { session.account }
    private var folder: String { model.folderName(account.configDir) }
    private var isOutputVisible: Bool { showOutput || session.phase.isFailure }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if let notice = testModeNotice {
                Label(notice, systemImage: "testtube.2")
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
                    command: model.claudeLoginMode == .simulated ? "claude auth login (simulado)" : "claude auth login",
                    text: session.output
                )
            }

            if session.phase == .connected {
                Label("Credenciais guardadas pelo Claude Code. O MultiCred não as armazena.", systemImage: "lock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                if canOpenBrowser, !session.phase.isFinished {
                    HStack {
                        Text("Abriu em \(BrowserChoice.label(for: browserChoice)). Navegador errado ou outra conta logada? Copie o link e cole em outro navegador ou numa janela anônima.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        AuthorizationLinkActions(url: session.authorizationURL)
                    }
                }
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
        .onChange(of: session.authorizationURL) { _, url in
            // The CLI does not open a browser (BROWSER is a no-op); open it here, once per link.
            guard let url, url != openedURL, canOpenBrowser else { return }
            openedURL = url
            BrowserChoice.open(url, choice: browserChoice)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "folder").font(.title2).foregroundStyle(.secondary).frame(width: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text("Login da pasta \(folder)").font(.headline)
                Text("Perfis: \(profileNames)")
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
                Button("Tentar de novo") { navigator.showClaudeFolderLogin(account.configDir, replacingTop: true) }
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
                Button("Concluir") { navigator.path = [] }.keyboardShortcut(.defaultAction)
            case .failed:
                Button("Voltar") { navigator.back() }
            default:
                Button("Cancelar") {
                    session.cancel()
                    navigator.back()
                }
            }
        }
    }

    /// The simulator's URL is fake; only the real CLI gives one worth opening.
    private var canOpenBrowser: Bool { model.claudeLoginMode != .simulated }

    private var testModeNotice: String? {
        switch model.claudeLoginMode {
        case .simulated:
            "Simulação do modo de teste: o navegador não abre. Digite qualquer código para conectar, ou \"erro\" para ver a tela de erro."
        case .realInSandbox:
            "Modo de teste com login real: o navegador abre e você entra numa conta de verdade, guardada numa pasta de teste. Depois do teste, use \"Sair\" na página da pasta para apagar esse login do Keychain."
        case .real:
            nil
        }
    }

    private var message: String {
        switch session.phase {
        case .starting, .waitingForBrowser:
            "O navegador vai abrir. A conta em que você entrar lá vira o login desta pasta. Se o navegador já estiver logado em outra conta Claude, saia dela antes ou abra o link numa janela anônima."
        case .waitingForCode:
            "Autorize no navegador. Se ele mostrar um código, cole abaixo; se a página disser que deu certo, é só aguardar."
        case .connecting:
            "Conectando ao Claude…"
        case .connected:
            "Pronto. Os perfis que usam \(folder) entram com esta conta quando não escolhem outra conta Claude."
        case let .failed(reason):
            session.launchError ?? "Não deu certo (\(reason)). O código vale por poucos minutos: gere outro no navegador e tente de novo."
        }
    }

    private var profileNames: String {
        let names = model.config.profiles.filter { $0.claudeConfigDir == account.configDir }.map(\.name)
        return names.isEmpty ? "nenhum" : names.joined(separator: ", ")
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
