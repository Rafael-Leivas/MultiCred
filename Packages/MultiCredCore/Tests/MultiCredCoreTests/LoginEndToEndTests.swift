import Foundation
import XCTest
@testable import MultiCredCore

/// Simulator → real pseudo-terminal → parser → state machine → status from the
/// state file, all inside the temporary HOME. This is the path the login window
/// takes in test mode.
final class LoginEndToEndTests: SafeTestCase {
    private final class Flow: @unchecked Sendable {
        private let lock = NSLock()
        private var parser = LoginOutputParser()
        private var machine = LoginStateMachine()
        var phase: LoginPhase { lock.withLock { machine.phase } }
        var transcript: String { lock.withLock { parser.transcript } }

        func output(_ data: Data) {
            lock.withLock {
                let events = parser.consume(data)
                events.forEach { machine.handle($0) }
            }
        }

        func codeSent() { lock.withLock { machine.codeSubmitted() } }
        func exited(_ status: Int32) { lock.withLock { machine.processExited(status: status) } }
    }

    private func login(account: ClaudeAccount, code: String, extraEnvironment: [String: String] = [:]) throws -> Flow {
        let flow = Flow()
        let pty = PseudoTerminalProcess()
        let exited = expectation(description: "exit")
        var env = ClaudeCLI.environment(for: account, base: ["HOME": home.path, "PATH": "/usr/bin:/bin"])
        env.merge(extraEnvironment) { $1 }
        try pty.start(
            executable: URL(fileURLWithPath: LoginSimulator.executable),
            arguments: LoginSimulator.arguments,
            environment: env,
            currentDirectory: home,
            onOutput: { flow.output($0) },
            onExit: { flow.exited($0); exited.fulfill() }
        )

        let deadline = Date().addingTimeInterval(5)
        while flow.phase != .waitingForCode, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertEqual(flow.phase, .waitingForCode, flow.transcript)
        pty.write(Data((code + "\r").utf8))
        flow.codeSent()
        XCTAssertEqual(flow.phase, .connecting)
        wait(for: [exited], timeout: 10)
        return flow
    }

    func testSuccessfulLoginMakesTheAccountLoggedIn() throws {
        let dir = home.appendingPathComponent(".claude-x")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let account = ClaudeAccount(nickname: "X", color: .teal, configDir: dir.path)

        let flow = try login(account: account, code: "ABC123")
        XCTAssertEqual(flow.phase, .connected)
        XCTAssertEqual(
            ClaudeAccountFiles.statusFromStateFile(for: account, environment: environment),
            .loggedIn(email: LoginSimulator.simulatedEmail)
        )
        XCTAssertNil(ClaudeAccountFiles.statusFromStateFile(for: ClaudeAccount(nickname: "d", color: .red, configDir: nil), environment: environment),
                     "the default account was not touched")
    }

    func testRejectedCodeEndsInFailure() throws {
        let account = ClaudeAccount(nickname: "D", color: .red, configDir: nil)
        let flow = try login(account: account, code: "erro-expirado")
        XCTAssertEqual(flow.phase, .failed("Error: Invalid code or expired"))
        XCTAssertNil(ClaudeAccountFiles.statusFromStateFile(for: account, environment: environment))
    }

    func testSimulatorRefusesToWriteOutsideHome() throws {
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("mc-outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        let account = ClaudeAccount(nickname: "O", color: .red, configDir: outside.path)

        let flow = try login(account: account, code: "ABC123")
        XCTAssertEqual(flow.phase, .failed("processo encerrado (código 3)"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent(".claude.json").path))
    }
}

/// setup-token simulator → real pseudo-terminal → parser: the token is captured
/// whole and never left visible in the transcript.
final class SetupTokenEndToEndTests: SafeTestCase {
    private final class Capture: @unchecked Sendable {
        private let lock = NSLock()
        private var parser = SetupTokenParser()
        private var machine = LoginStateMachine()
        var phase: LoginPhase { lock.withLock { machine.phase } }
        var token: String? { lock.withLock { parser.token } }
        var masked: String { lock.withLock { parser.maskedTranscript } }
        func output(_ data: Data) { lock.withLock { parser.consume(data).forEach { machine.handle($0) } } }
    }

    func testSimulatedSetupTokenIsCapturedAndMasked() throws {
        let capture = Capture()
        let pty = PseudoTerminalProcess()
        let exited = expectation(description: "exit")
        try pty.start(
            executable: URL(fileURLWithPath: SetupTokenSimulator.executable),
            arguments: SetupTokenSimulator.arguments,
            environment: ["HOME": home.path, "PATH": "/usr/bin:/bin"],
            currentDirectory: home,
            columns: 500,
            onOutput: { capture.output($0) },
            onExit: { _ in exited.fulfill() }
        )
        let deadline = Date().addingTimeInterval(5)
        while capture.phase != .waitingForCode, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertEqual(capture.phase, .waitingForCode, capture.masked)
        pty.write(Data("CODE\r".utf8))
        wait(for: [exited], timeout: 10)

        XCTAssertEqual(capture.token, SetupTokenSimulator.fakeToken)
        XCTAssertFalse(capture.masked.contains(SetupTokenSimulator.fakeToken))
    }
}
