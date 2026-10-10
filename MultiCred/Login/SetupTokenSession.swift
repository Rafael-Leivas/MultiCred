import AppKit
import MultiCredCore
import Observation

/// One `claude setup-token` run in a pseudo-terminal, in a throwaway config
/// folder so no profile folder is touched. The browser decides which Claude
/// account the token belongs to. The token is handed to `onToken` once (it goes
/// straight to the Keychain) and never shown: the visible output is masked.
@MainActor
@Observable
final class SetupTokenSession {
    private(set) var machine = LoginStateMachine()
    private(set) var output = ""
    private(set) var launchError: String?
    private(set) var tokenCaptured = false

    @ObservationIgnored private let pty = PseudoTerminalProcess()
    @ObservationIgnored private var parser = SetupTokenParser()
    @ObservationIgnored private var sentCodes: [String] = []
    @ObservationIgnored private var scratch: URL?
    @ObservationIgnored private let onToken: (String) -> Void
    @ObservationIgnored private let cleanup: (URL) -> Void

    var phase: LoginPhase { machine.phase }
    var authorizationURL: URL? { machine.authorizationURL }

    init(onToken: @escaping (String) -> Void, cleanup: @escaping (URL) -> Void) {
        self.onToken = onToken
        self.cleanup = cleanup
    }

    func start(_ command: LoginCommand, scratchFolder: URL?) {
        scratch = scratchFolder
        do {
            try pty.start(
                executable: URL(fileURLWithPath: command.executable),
                arguments: command.arguments,
                environment: command.environment,
                currentDirectory: URL(fileURLWithPath: command.workingDirectory),
                // Wide, so the ~108-character token is printed on one line.
                columns: 500,
                onOutput: { [weak self] data in
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.received(data) } }
                },
                onExit: { [weak self] status in
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.exited(status) } }
                }
            )
        } catch {
            launchError = "Não consegui iniciar o claude setup-token: \(error)"
            machine.handle(.failed(launchError!))
        }
    }

    func submit(code: String) {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, machine.phase.acceptsCode else { return }
        sentCodes.append(trimmed)
        pty.write(Data((trimmed + "\r").utf8))
        machine.codeSubmitted()
    }

    func openBrowserAgain() {
        if let url = authorizationURL { NSWorkspace.shared.open(url) }
    }

    func copyLink() {
        guard let url = authorizationURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    func stop() {
        pty.terminate()
        removeScratch()
    }

    private func received(_ data: Data) {
        let events = parser.consume(data)
        output = Redactor.redact(parser.maskedTranscript, secrets: sentCodes)
        events.forEach { machine.handle($0) }
        deliverTokenIfReady()
    }

    private func exited(_ status: Int32) {
        deliverTokenIfReady()
        if tokenCaptured {
            machine.handle(.succeeded)
        } else {
            machine.processExited(status: status == 0 ? 1 : status)
            if status == 0 { launchError = "O Claude Code terminou sem mostrar um token. Tente de novo ou cole o token manualmente." }
        }
        removeScratch()
    }

    private func deliverTokenIfReady() {
        guard !tokenCaptured, let token = parser.token else { return }
        tokenCaptured = true
        onToken(token)
    }

    private func removeScratch() {
        guard let scratch else { return }
        self.scratch = nil
        cleanup(scratch)
    }
}

enum SetupTokenCommand {
    /// Real modes: `claude setup-token` with a throwaway CLAUDE_CONFIG_DIR.
    /// Test mode (simulated): a script that prints a fake token.
    static func make(model: AppModel) async -> (Result<LoginCommand, UserFacingError>, URL?) {
        let environment = model.environment
        var env = environment.baseProcessEnvironment(path: await model.tools.searchDirectories())
        env["TERM"] = "xterm-256color"
        if model.claudeLoginMode == .simulated {
            return (.success(LoginCommand(executable: SetupTokenSimulator.executable, arguments: SetupTokenSimulator.arguments, environment: env, workingDirectory: environment.home.path)), nil)
        }
        guard let claude = await model.claudeLocator.locate(.claude) else {
            return (.failure(UserFacingError(text: LoginLaunchError.claudeNotInstalled.message)), nil)
        }
        let scratch = environment.appSupportDirectory.appendingPathComponent("setup-token-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            return (.failure(UserFacingError(text: "Não consegui criar a pasta temporária: \(error.localizedDescription)")), nil)
        }
        env["CLAUDE_CONFIG_DIR"] = scratch.path
        env["PATH"] = ([claude.deletingLastPathComponent().path] + (env["PATH"].map { [$0] } ?? [])).joined(separator: ":")
        return (.success(LoginCommand(executable: claude.path, arguments: ["setup-token"], environment: env, workingDirectory: environment.home.path)), scratch)
    }
}
