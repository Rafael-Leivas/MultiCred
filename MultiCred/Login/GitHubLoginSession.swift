import AppKit
import MultiCredCore
import Observation

/// One `gh auth login --web` attempt in a pseudo-terminal. gh shows a one-time
/// code and waits for Enter to open the browser; the user copies the code and
/// presses "Abrir o GitHub". Yes/no questions are answered with the default.
/// gh stores the token itself; MultiCred never sees it.
@MainActor
@Observable
final class GitHubLoginSession {
    let host: String
    private(set) var machine = GitHubLoginStateMachine()
    private(set) var output = ""
    private(set) var launchError: String?

    @ObservationIgnored private let pty = PseudoTerminalProcess()
    @ObservationIgnored private var parser = GitHubLoginParser()
    @ObservationIgnored private let onFinished: (GitHubLoginPhase) -> Void

    var phase: GitHubLoginPhase { machine.phase }
    var code: String? { machine.code }

    init(host: String, onFinished: @escaping (GitHubLoginPhase) -> Void) {
        self.host = host
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
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.received(data) } }
                },
                onExit: { [weak self] status in
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            guard let self else { return }
                            self.update { $0.processExited(status: status, login: self.parser.loggedInAs) }
                        }
                    }
                }
            )
        } catch {
            failToLaunch("Não consegui iniciar o login do GitHub: \(error)")
        }
    }

    func failToLaunch(_ message: String) {
        launchError = message
        update { $0.handle(.failed(message)) }
    }

    /// Copies the code and lets gh open the browser (it waits for Enter).
    func openBrowser() {
        if let code {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(code, forType: .string)
        }
        pty.write(Data("\r".utf8))
        update { $0.browserOpened() }
    }

    func cancel() {
        update { $0.cancelled() }
        stop()
    }

    func stop() {
        pty.terminate()
    }

    private func received(_ data: Data) {
        let events = parser.consume(data)
        output = parser.transcript
        for event in events {
            if case .question = event { pty.write(Data("\r".utf8)) }
        }
        guard !events.isEmpty else { return }
        update { machine in events.forEach { machine.handle($0) } }
    }

    private func update(_ change: (inout GitHubLoginStateMachine) -> Void) {
        let wasFinished = machine.phase.isFinished
        change(&machine)
        if !wasFinished, machine.phase.isFinished {
            onFinished(machine.phase)
        }
    }
}

struct UserFacingError: Error {
    let text: String
}

enum GitHubLoginCommand {
    /// Real mode: `gh auth login --web`. Test mode: the simulator (gh in a
    /// sandbox would still write the token to the real Keychain).
    static func make(host: String, model: AppModel) async -> Result<LoginCommand, UserFacingError> {
        let environment = model.environment
        var env = environment.baseProcessEnvironment(path: await model.tools.searchDirectories())
        env["TERM"] = "xterm-256color"
        if environment.mode == .real {
            guard let gh = await model.tools.locate(.gh) else {
                return .failure(UserFacingError(text: "GitHub CLI não foi encontrado. Instale com: brew install gh"))
            }
            return .success(LoginCommand(executable: gh.path, arguments: GitHubCLI.loginArguments(host: host), environment: env, workingDirectory: environment.home.path))
        }
        return .success(LoginCommand(
            executable: GitHubLoginSimulator.executable,
            arguments: GitHubLoginSimulator.arguments,
            environment: env,
            workingDirectory: environment.home.path
        ))
    }
}
