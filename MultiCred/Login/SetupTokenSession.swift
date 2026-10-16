import AppKit
import MultiCredCore
import Observation

/// One `claude setup-token` run in a pseudo-terminal, in a throwaway config
/// folder so no profile folder is touched. The browser decides which Claude
/// account the token belongs to. The token is handed to `onToken` once (it goes
/// straight to the Keychain) and never shown: the visible output is masked.
///
/// The authorization page shows a code to copy (there is no redirect back to
/// the app). While waiting for it, the clipboard is watched: when a copied text
/// has the code's shape, it is sent to the CLI and MultiCred comes forward.
@MainActor
@Observable
final class SetupTokenSession {
    static let stallAfter: Duration = .seconds(25)

    private(set) var machine = LoginStateMachine()
    private(set) var output = ""
    private(set) var launchError: String?
    private(set) var tokenCaptured = false
    /// The code was sent but the CLI has not answered for a while.
    private(set) var stalled = false
    /// The last code came from the clipboard (shown in the UI).
    private(set) var codeFromClipboard = false

    @ObservationIgnored private let pty = PseudoTerminalProcess()
    @ObservationIgnored private var parser = SetupTokenParser()
    @ObservationIgnored private var sentCodes: [String] = []
    @ObservationIgnored private var scratch: URL?
    @ObservationIgnored private var clipboardTask: Task<Void, Never>?
    @ObservationIgnored private var stallTask: Task<Void, Never>?
    @ObservationIgnored private var logged = false
    @ObservationIgnored private let onToken: (String) -> Void
    @ObservationIgnored private let cleanup: (URL) -> Void
    @ObservationIgnored private let log: (String) -> Void

    var phase: LoginPhase { machine.phase }
    var authorizationURL: URL? { machine.authorizationURL }
    var isWaitingForCode: Bool { !phase.isFinished && phase != .connecting }

    init(onToken: @escaping (String) -> Void, cleanup: @escaping (URL) -> Void, log: @escaping (String) -> Void) {
        self.onToken = onToken
        self.cleanup = cleanup
        self.log = log
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
            return
        }
        watchClipboard()
    }

    func submit(code: String, fromClipboard: Bool = false) {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, machine.phase.acceptsCode else { return }
        sentCodes.append(trimmed)
        codeFromClipboard = fromClipboard
        pty.submitLine(trimmed)
        machine.codeSubmitted()
        stalled = false
        stallTask?.cancel()
        stallTask = Task { [weak self] in
            try? await Task.sleep(for: Self.stallAfter)
            guard let self, !Task.isCancelled, self.phase == .connecting else { return }
            self.stalled = true
            self.writeLog(reason: "no answer \(Self.stallAfter) after the code")
        }
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
        clipboardTask?.cancel()
        stallTask?.cancel()
        pty.terminate()
        if !tokenCaptured { writeLog(reason: "stopped") }
        removeScratch()
    }

    private func received(_ data: Data) {
        let events = parser.consume(data)
        output = Redactor.redactCredentialLike(parser.maskedTranscript, secrets: sentCodes)
        events.forEach { machine.handle($0) }
        if phase.isFinished { stallTask?.cancel(); stalled = false }
        if case .failed = phase { writeLog(reason: "failed") }
        deliverTokenIfReady()
    }

    private func exited(_ status: Int32) {
        deliverTokenIfReady()
        clipboardTask?.cancel()
        stallTask?.cancel()
        stalled = false
        if tokenCaptured {
            machine.handle(.succeeded)
        } else {
            machine.processExited(status: status == 0 ? 1 : status)
            if status == 0 { launchError = "O Claude Code terminou sem mostrar um token. Tente de novo ou cole o token manualmente." }
            writeLog(reason: "exited \(status) without a token")
        }
        removeScratch()
    }

    private func deliverTokenIfReady() {
        guard !tokenCaptured, let token = parser.token else { return }
        tokenCaptured = true
        clipboardTask?.cancel()
        stallTask?.cancel()
        log("setup-token: token received (kept only in the Keychain)")
        onToken(token)
    }

    /// Polls the clipboard's change count; reads it only when it changed after
    /// the session started, and only acts on text shaped like the code.
    private func watchClipboard() {
        let pasteboard = NSPasteboard.general
        var lastCount = pasteboard.changeCount
        clipboardTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, !Task.isCancelled else { return }
                guard pasteboard.changeCount != lastCount else { continue }
                lastCount = pasteboard.changeCount
                guard self.machine.phase.acceptsCode,
                      let text = pasteboard.string(forType: .string),
                      AuthorizationCode.looksLikeCode(text) else { continue }
                self.submit(code: text, fromClipboard: true)
                NSApp.activate()
            }
        }
    }

    /// Masked CLI output, for diagnosing a flow that did not end with a token.
    private func writeLog(reason: String) {
        guard !logged else { return }
        logged = true
        let masked = Redactor.redactCredentialLike(parser.maskedTranscript, secrets: sentCodes)
        log("setup-token \(reason); phase=\(phase); output (masked, last 3000):\n\(masked.suffix(3000))")
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
        // The page opens the link in the browser the user picked.
        env["BROWSER"] = BrowserChoice.suppressCLIBrowser
        env["PATH"] = ([claude.deletingLastPathComponent().path] + (env["PATH"].map { [$0] } ?? [])).joined(separator: ":")
        return (.success(LoginCommand(executable: claude.path, arguments: ["setup-token"], environment: env, workingDirectory: environment.home.path)), scratch)
    }
}
