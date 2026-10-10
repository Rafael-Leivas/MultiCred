import MultiCredCore
import SwiftUI

/// Add a Claude account (credential only) or replace its token.
/// Browser flow: `claude setup-token` runs hidden; the page shows three steps,
/// picks the code up from the clipboard, and keeps the raw output behind
/// "Detalhes técnicos".
struct AddClaudeAccountPage: View {
    let model: AppModel
    let navigator: MainNavigator
    /// nil = new account; otherwise only its token is replaced.
    var replacing: UUID?

    private enum Source: Hashable { case browser, paste }

    @State private var nickname = ""
    @State private var email = ""
    @State private var color: ProfileColor = .teal
    @State private var source: Source = .browser
    @State private var pasted = ""
    @State private var session: SetupTokenSession?
    @State private var code = ""
    @State private var saved: ClaudeAccount?
    @State private var startError: String?
    @State private var showDetails = false

    private var existing: ClaudeAccount? { replacing.flatMap { model.config.claudeAccount($0) } }
    private var displayName: String { existing?.nickname ?? nickname.trimmingCharacters(in: .whitespaces) }
    private var canStart: Bool { !displayName.isEmpty }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let saved {
                    done(saved)
                } else if let session {
                    running(session)
                } else {
                    setup
                }
            }
            .padding(24)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(existing.map { "Novo token de \($0.nickname)" } ?? "Adicionar conta Claude")
        .onDisappear { session?.stop() }
    }

    // MARK: Before starting

    @ViewBuilder private var setup: some View {
        Text("Uma conta Claude é só o login. Usada num perfil, ela mantém os agents, skills e conversas da pasta do perfil.")
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        if existing == nil {
            Form {
                TextField("Apelido", text: $nickname, prompt: Text("Ex.: Marco"))
                TextField("E-mail da conta", text: $email, prompt: Text("opcional"))
                LabeledContent("Cor") { ColorChooser(selection: $color) }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(height: 170)
            .padding(.horizontal, -20)
        }

        Picker("", selection: $source) {
            Text("Entrar pelo navegador").tag(Source.browser)
            Text("Já tenho um token").tag(Source.paste)
        }
        .pickerStyle(.segmented)
        .labelsHidden()

        switch source {
        case .browser:
            VStack(alignment: .leading, spacing: 12) {
                Text("O navegador abre na página do Claude. Entre com a conta que você quer adicionar, clique em Autorizar e copie o código mostrado. O MultiCred pega o código copiado sozinho.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                if model.claudeLoginMode == .simulated {
                    Label("Modo de teste: simulação; digite qualquer código.", systemImage: "testtube.2")
                        .font(.callout).foregroundStyle(.orange)
                }
                HStack {
                    Spacer()
                    Button("Cancelar") { navigator.back() }
                    Button("Continuar no navegador") { start() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .disabled(!canStart)
                }
            }
        case .paste:
            VStack(alignment: .leading, spacing: 12) {
                Text("Se você já rodou \"claude setup-token\" num terminal, cole o token (começa com sk-ant-oat).")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                SecureField("sk-ant-oat01-…", text: $pasted)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                HStack {
                    Spacer()
                    Button("Cancelar") { navigator.back() }
                    Button("Salvar") { save(token: pasted) }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .disabled(!canStart || pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        if let startError {
            Label(startError, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.red)
        }
    }

    // MARK: While running

    @ViewBuilder private func running(_ session: SetupTokenSession) -> some View {
        HStack(spacing: 12) {
            AccountAvatar(name: displayName, color: existing?.color ?? color, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(displayName).font(.title3.weight(.semibold))
                Text(existing?.email ?? (email.isEmpty ? "Conta Claude" : email)).foregroundStyle(.secondary)
            }
        }

        VStack(alignment: .leading, spacing: 14) {
            StepRow(number: 1, state: step1(session), title: "Entre no navegador com a conta que você quer usar") {
                HStack(spacing: 12) {
                    Button("Abrir de novo") { session.openBrowserAgain() }
                    Button("Copiar link") { session.copyLink() }
                }
                .buttonStyle(.link)
                .font(.caption)
                .disabled(session.authorizationURL == nil || model.claudeLoginMode == .simulated)
                Text("Já está logado em outra conta Claude? Saia dela no navegador, ou cole o link numa janela anônima.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            StepRow(number: 2, state: step2(session), title: "Clique em Autorizar e copie o código") {
                if session.isWaitingForCode {
                    Text("Assim que você copiar, o MultiCred envia o código e volta para a frente.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        TextField("Ou cole o código aqui", text: $code)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                            .onSubmit(sendCode)
                        Button("Enviar", action: sendCode)
                            .disabled(code.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } else if session.codeFromClipboard {
                    Text("Código copiado recebido.").font(.caption).foregroundStyle(.secondary)
                }
            }
            StepRow(number: 3, state: step3(session), title: "Gerar o token") {
                if session.phase == .connecting {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Gerando o token…").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if session.stalled {
                    Text("Está demorando mais que o normal. Abra os detalhes técnicos abaixo ou tente de novo; a saída (sem códigos nem tokens) foi registrada no log.")
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))

        if case let .failed(reason) = session.phase {
            Label(session.launchError ?? failureText(reason), systemImage: "exclamationmark.triangle")
                .font(.callout).foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }

        DisclosureGroup("Detalhes técnicos", isExpanded: $showDetails) {
            TerminalOutput(directory: "pasta temporária (apagada no fim)",
                           command: model.claudeLoginMode == .simulated ? "claude setup-token (simulado)" : "claude setup-token",
                           text: session.output)
                .padding(.top, 6)
        }
        .font(.callout)
        .foregroundStyle(.secondary)

        HStack {
            Spacer()
            if session.phase.isFailure || session.stalled {
                Button("Tentar de novo") { start() }
            }
            Button("Cancelar") {
                session.stop()
                self.session = nil
            }
        }
    }

    private func step1(_ session: SetupTokenSession) -> StepState {
        session.phase == .starting ? .active : .done
    }

    private func step2(_ session: SetupTokenSession) -> StepState {
        if session.phase == .starting { return .pending }
        return session.isWaitingForCode ? .active : .done
    }

    private func step3(_ session: SetupTokenSession) -> StepState {
        switch session.phase {
        case .connecting: .active
        case .connected: .done
        case .failed: .failed
        default: .pending
        }
    }

    private func failureText(_ reason: String) -> String {
        if reason.lowercased().contains("400") {
            return "O Claude recusou o código. Ele vale uma vez e por poucos minutos, e só para o link aberto nesta tentativa. Tente de novo."
        }
        return "Não deu certo (\(reason))."
    }

    // MARK: Done

    private func done(_ account: ClaudeAccount) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(existing != nil ? "Token de \(account.nickname) trocado." : "Conta \(account.nickname) adicionada.", systemImage: "checkmark.circle.fill")
                .font(.title3).foregroundStyle(.green)
            Text("O token está só no Keychain. Escolha esta conta no editor de um perfil, ou use agora no perfil ativo sem trocar de pasta.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                if let profile = model.activeProfile {
                    Button("Usar agora em \(profile.name)") {
                        Task {
                            if let error = await model.switchClaudeOnly(to: account.id) { model.lastError = error } else { navigator.path = [] }
                        }
                    }
                }
                Button("Concluir") { navigator.path = [] }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: Actions

    private func start() {
        startError = nil
        session?.stop()
        let log = model.log
        let new = SetupTokenSession(
            onToken: { token in save(token: token) },
            cleanup: { url in
                // Only the throwaway folder created for this run.
                if url.lastPathComponent.hasPrefix("setup-token-") { try? FileManager.default.removeItem(at: url) }
            },
            log: { log.log(.info, $0) }
        )
        session = new
        Task {
            let (command, scratch) = await SetupTokenCommand.make(model: model)
            switch command {
            case let .success(command):
                model.log.log(.info, "setup-token started for \(displayName) (\(model.claudeLoginMode))")
                new.start(command, scratchFolder: scratch)
            case let .failure(error):
                startError = error.text
                session = nil
            }
        }
    }

    private func sendCode() {
        session?.submit(code: code)
        code = ""
    }

    private func save(token: String) {
        if let existing {
            if model.replaceClaudeToken(of: existing, with: token) { saved = existing }
        } else {
            let mail = email.trimmingCharacters(in: .whitespaces)
            saved = model.addClaudeTokenAccount(nickname: nickname, email: mail.isEmpty ? nil : mail, color: color, token: token)
        }
        pasted = ""
    }
}

/// A numbered step with a state icon and optional detail below the title.
struct StepRow<Detail: View>: View {


    let number: Int
    let state: StepState
    let title: String
    @ViewBuilder var detail: Detail

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(circleColor).frame(width: 24, height: 24)
                switch state {
                case .done: Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(.white)
                case .failed: Image(systemName: "xmark").font(.caption.weight(.bold)).foregroundStyle(.white)
                default: Text("\(number)").font(.caption.weight(.bold)).foregroundStyle(state == .active ? .white : .secondary)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.body.weight(state == .active ? .semibold : .regular))
                    .foregroundStyle(state == .pending ? .secondary : .primary)
                if state == .active || state == .failed { detail }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var circleColor: Color {
        switch state {
        case .pending: Color.primary.opacity(0.08)
        case .active: .accentColor
        case .done: .green
        case .failed: .red
        }
    }
}

enum StepState: Equatable { case pending, active, done, failed }
