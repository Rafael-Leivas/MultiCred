import Foundation
import XCTest
@testable import MultiCredCore

/// Uses only /bin/sh with inline scripts.
final class PseudoTerminalProcessTests: XCTestCase {
    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
        func append(_ chunk: Data) { lock.withLock { data.append(chunk) } }
    }

    private func run(
        _ script: String,
        input: String? = nil,
        inputDelay: TimeInterval = 0.3,
        timeout: TimeInterval = 10
    ) -> (output: String, status: Int32?) {
        let pty = PseudoTerminalProcess()
        let output = Collector()
        let exited = expectation(description: "exit")
        nonisolated(unsafe) var status: Int32?
        do {
            try pty.start(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", script],
                environment: ["PATH": "/usr/bin:/bin"],
                onOutput: { output.append($0) },
                onExit: { status = $0; exited.fulfill() }
            )
        } catch {
            XCTFail("start failed: \(error)")
            return ("", nil)
        }
        if let input {
            DispatchQueue.global().asyncAfter(deadline: .now() + inputDelay) { pty.write(Data(input.utf8)) }
        }
        wait(for: [exited], timeout: timeout)
        return (output.text, status)
    }

    func testChildSeesATerminal() {
        let result = run("[ -t 0 ] && [ -t 1 ] && echo tty-ok; stty size")
        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("tty-ok"), result.output)
        XCTAssertTrue(result.output.contains("24 100"), "window size is applied: \(result.output)")
    }

    func testInputIsDeliveredLikeTyping() {
        let result = run("printf 'Paste code here if prompted > '; IFS= read -r code; printf 'got:%s\\n' \"$code\"", input: "ABC-123\r")
        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("got:ABC-123"), result.output)
    }

    func testExitStatusAndAllOutputArriveBeforeExit() {
        let result = run("i=0; while [ $i -lt 2000 ]; do echo line$i; i=$((i+1)); done; exit 7")
        XCTAssertEqual(result.status, 7)
        XCTAssertTrue(result.output.contains("line1999"), "output must be drained before onExit")
    }

    func testExitIsReportedEvenIfAGrandchildKeepsTheTerminal() {
        let start = Date()
        let result = run("sleep 30 & echo started")
        XCTAssertEqual(result.status, 0)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    func testTerminateStopsALongRunningChild() {
        let pty = PseudoTerminalProcess()
        let exited = expectation(description: "exit")
        XCTAssertNoThrow(try pty.start(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "sleep 60"],
            environment: [:],
            onOutput: { _ in },
            onExit: { _ in exited.fulfill() }
        ))
        XCTAssertTrue(pty.isRunning)
        pty.terminate()
        wait(for: [exited], timeout: 5)
        XCTAssertFalse(pty.isRunning)
    }

    func testLaunchFailureAndDoubleStart() {
        let pty = PseudoTerminalProcess()
        XCTAssertThrowsError(try pty.start(
            executable: URL(fileURLWithPath: "/nonexistent/claude"), arguments: [], environment: [:],
            onOutput: { _ in }, onExit: { _ in }
        ))
        let running = PseudoTerminalProcess()
        XCTAssertNoThrow(try running.start(
            executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "sleep 5"], environment: [:],
            onOutput: { _ in }, onExit: { _ in }
        ))
        XCTAssertThrowsError(try running.start(
            executable: URL(fileURLWithPath: "/bin/sh"), arguments: [], environment: [:],
            onOutput: { _ in }, onExit: { _ in }
        )) { XCTAssertEqual($0 as? PseudoTerminalProcess.PTYError, .alreadyStarted) }
        running.terminate()
    }
}
