import AppKit
import MultiCredCore
import Observation

/// One login attempt for one Claude account: runs `claude auth login` in a
/// pseudo-terminal with the account's `CLAUDE_CONFIG_DIR`, tracks the phase and
/// forwards a pasted code to the process. The code is never stored, and both the
/// on-screen output and the copied log show it masked. Credentials are written
/// by Claude Code itself, never by MultiCred.
@MainActor
@Observable
final class LoginSession {
    static let timeout: Duration = .seconds(600)

    let account: ClaudeAccount
    private(set) var machine = LoginStateMachine()
    private(set) var launchError: String?
    /// Visible output, escape sequences removed, codes masked.
    private(set) var output = ""

    @ObservationIgnored private let pty = PseudoTerminalProcess()
    @ObservationIgnored private var parser = LoginOutputParser()
    @ObservationIgnored private var sentCodes: [String] = []
    @ObservationIgnored private var timeoutTask: Task<Void, Never>?
    @ObservationIgnored private let onFinished: (LoginPhase) -> Void

    var phase: LoginPhase { machine.phase }
    var authorizationURL: URL? { machine.authorizationURL }

    init(account: ClaudeAccount, onFinished: @escaping (LoginPhase) -> Void) {
        self.account = account
        self.onFinished = onFinished
    }

    func start(_ command: LoginCommand) {
        do {
            try pty.start(
                executable: URL(fileURLWithPath: command.executable),
                arguments: command.arguments,
                environment: command.environment,
                currentDirectory: URL(fileURLWithPath: command.workingDirectory),
                onOutput: { [weak self] data in
                    Task { @MainActor in self?.received(data) }
                },
                onExit: { [weak self] status in
                    Task { @MainActor in self?.update { $0.processExited(status: status) } }
                }
            )
        } catch {
            failToLaunch("Não consegui iniciar o login: \(error)")
            return
        }
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: Self.timeout)
            guard let self, !Task.isCancelled else { return }
            self.update { $0.timedOut() }
            self.pty.terminate()
        }
    }

    func failToLaunch(_ message: String) {
        launchError = message
        update { $0.handle(.failed(message)) }
    }

    /// Sends the pasted code to the process followed by Enter.
    func submit(code: String) {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, machine.phase.acceptsCode else { return }
        sentCodes.append(trimmed)
        pty.write(Data((trimmed + "\r").utf8))
        update { $0.codeSubmitted() }
    }

    func openBrowserAgain() {
        if let url = authorizationURL { NSWorkspace.shared.open(url) }
    }

    func cancel() {
        update { $0.cancelled() }
        stop()
    }

    func stop() {
        timeoutTask?.cancel()
        pty.terminate()
    }

    /// For "Copiar log".
    var redactedLog: String {
        Redactor.redact(parser.transcript, secrets: sentCodes)
    }

    private func received(_ data: Data) {
        let events = parser.consume(data)
        output = redactedLog
        guard !events.isEmpty else { return }
        update { machine in events.forEach { machine.handle($0) } }
    }

    private func update(_ change: (inout LoginStateMachine) -> Void) {
        let wasFinished = machine.phase.isFinished
        change(&machine)
        if !wasFinished, machine.phase.isFinished {
            timeoutTask?.cancel()
            onFinished(machine.phase)
        }
    }
}

/// What to run for a login attempt.
struct LoginCommand {
    let executable: String
    let arguments: [String]
    let environment: [String: String]
    let workingDirectory: String

    /// Real mode: `claude auth login`. Test mode: a shell script that prints what
    /// the real CLI printed in the spike, so the window can be exercised without
    /// touching Claude Code. It only writes inside the sandbox home.
    static func make(for account: ClaudeAccount, model: AppModel) async -> Result<LoginCommand, LoginLaunchError> {
        let environment = model.environment
        var env = ClaudeCLI.environment(
            for: account,
            base: environment.baseProcessEnvironment(path: await model.tools.searchDirectories())
        )
        env["TERM"] = "xterm-256color"
        env["NO_COLOR"] = nil

        if environment.mode == .real {
            guard let claude = await model.tools.locate(.claude) else { return .failure(.claudeNotInstalled) }
            return .success(LoginCommand(executable: claude.path, arguments: ["auth", "login"], environment: env, workingDirectory: environment.home.path))
        }
        return .success(LoginCommand(
            executable: LoginSimulator.executable,
            arguments: LoginSimulator.arguments,
            environment: env,
            workingDirectory: environment.home.path
        ))
    }
}

enum LoginLaunchError: Error {
    case claudeNotInstalled

    var message: String {
        switch self {
        case .claudeNotInstalled: "Claude Code não foi encontrado. Instale com: curl -fsSL https://claude.ai/install.sh | bash"
        }
    }
}
