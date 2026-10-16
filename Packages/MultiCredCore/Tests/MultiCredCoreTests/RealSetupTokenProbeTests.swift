import Foundation
import XCTest
@testable import MultiCredCore

/// Opt-in probe of the real `claude setup-token` through the app's own path
/// (PseudoTerminalProcess + SetupTokenParser + LoginStateMachine), with a
/// throwaway CLAUDE_CONFIG_DIR and a fake code. Changes nothing real.
/// Run with MULTICRED_SETUP_TOKEN_PROBE=<path to claude>.
final class RealSetupTokenProbeTests: XCTestCase {
    private final class Capture: @unchecked Sendable {
        private let lock = NSLock()
        private var parser = SetupTokenParser()
        private(set) var machine = LoginStateMachine()
        private(set) var raw = Data()
        var phase: LoginPhase { lock.withLock { machine.phase } }
        var transcript: String { lock.withLock { parser.maskedTranscript } }
        func output(_ data: Data) {
            lock.withLock {
                raw.append(data)
                parser.consume(data).forEach { machine.handle($0) }
            }
        }
        func codeSent() { lock.withLock { machine.codeSubmitted() } }
    }

    func testFakeCodeEndsInFailure() throws {
        guard let claude = ProcessInfo.processInfo.environment["MULTICRED_SETUP_TOKEN_PROBE"] else {
            throw XCTSkip("set MULTICRED_SETUP_TOKEN_PROBE to the claude binary")
        }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("setup-token-probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let capture = Capture()
        let pty = PseudoTerminalProcess()
        let env = [
            "HOME": NSHomeDirectory(), "USER": NSUserName(), "LANG": "en_US.UTF-8", "SHELL": "/bin/zsh",
            "PATH": URL(fileURLWithPath: claude).deletingLastPathComponent().path + ":/usr/bin:/bin",
            "TERM": "xterm-256color", "CLAUDE_CONFIG_DIR": scratch.path, "BROWSER": "/usr/bin/true",
        ]
        try pty.start(executable: URL(fileURLWithPath: claude), arguments: ["setup-token"], environment: env,
                      currentDirectory: scratch, columns: 500, onOutput: { capture.output($0) }, onExit: { _ in })
        defer { pty.terminate() }

        func run(until done: () -> Bool, seconds: Double) {
            let deadline = Date().addingTimeInterval(seconds)
            while !done(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        }
        run(until: { capture.phase == .waitingForCode }, seconds: 15)
        print("PHASE BEFORE CODE:", capture.phase)
        // Real codes are ~90 characters; sent with code + "\r" in one write,
        // Claude Code 2.1.301 swallows the Enter. submitLine must get an answer.
        pty.submitLine("BfakeAbCdEfGhIjKlMnOpQrStUvWxYz0123456789abcdefg#fakeSTATEabcdefghijklmnopqrstuvwxyz0123456789ABCDE")
        capture.codeSent()
        run(until: { capture.phase.isFinished }, seconds: 15)
        print("PHASE AFTER CODE:", capture.phase)
        print("TRANSCRIPT TAIL:", String(capture.transcript.suffix(800)))
        XCTAssertEqual(capture.phase.isFinished, true)
    }
}
