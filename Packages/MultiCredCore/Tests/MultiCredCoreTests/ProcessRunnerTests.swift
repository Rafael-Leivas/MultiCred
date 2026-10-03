import Foundation
import XCTest
@testable import MultiCredCore

/// Runs only harmless system binaries (/bin/echo, /bin/sh with inline scripts, /bin/cat).
final class ProcessRunnerTests: XCTestCase {
    private let runner = ProcessRunner()
    private let sh = URL(fileURLWithPath: "/bin/sh")

    func testCapturesStdoutAndExitCode() async throws {
        let result = try await runner.run(CommandRequest(executable: URL(fileURLWithPath: "/bin/echo"), arguments: ["hello", "world"]))
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "hello world\n")
    }

    func testArgumentsAreNotInterpretedByAShell() async throws {
        let tricky = "$(touch /tmp/should-not-exist); `id` 'quoted' \"double\""
        let result = try await runner.run(CommandRequest(executable: URL(fileURLWithPath: "/bin/echo"), arguments: [tricky]))
        XCTAssertEqual(result.stdout, tricky + "\n")
    }

    func testNonZeroExitAndStderr() async throws {
        let result = try await runner.run(CommandRequest(executable: sh, arguments: ["-c", "echo oops >&2; exit 3"]))
        XCTAssertEqual(result.exitCode, 3)
        XCTAssertEqual(result.stderr, "oops\n")

        do {
            try await runner.runChecked(CommandRequest(executable: sh, arguments: ["-c", "exit 4"]))
            XCTFail("expected nonZeroExit")
        } catch let error as CommandError {
            XCTAssertEqual(error, .nonZeroExit(executable: "sh", code: 4, stderr: ""))
        }
    }

    func testEnvironmentIsExplicitAndNotInherited() async throws {
        let result = try await runner.run(CommandRequest(
            executable: sh,
            arguments: ["-c", "printf '%s|%s' \"$ONLY_THIS\" \"${HOME-unset}\""],
            environment: ["ONLY_THIS": "yes"]
        ))
        XCTAssertEqual(result.stdout, "yes|unset")
    }

    func testStandardInputIsDelivered() async throws {
        let result = try await runner.run(CommandRequest(
            executable: URL(fileURLWithPath: "/bin/cat"),
            standardInput: Data("from stdin".utf8)
        ))
        XCTAssertEqual(result.stdout, "from stdin")
    }

    func testLargeOutputOnBothPipesDoesNotDeadlock() async throws {
        // 200 KB on each pipe, well over the 64 KB pipe buffer.
        let script = "i=0; while [ $i -lt 4000 ]; do echo 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'; echo 'yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy' >&2; i=$((i+1)); done"
        let result = try await runner.run(CommandRequest(executable: sh, arguments: ["-c", script], timeout: .seconds(30)))
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.standardOutput.count, 4000 * 47)
        XCTAssertEqual(result.standardError.count, 4000 * 47)
    }

    func testTimeoutKillsTheProcess() async throws {
        let start = Date()
        do {
            _ = try await runner.run(CommandRequest(executable: sh, arguments: ["-c", "sleep 30"], timeout: .milliseconds(300)))
            XCTFail("expected timeout")
        } catch let error as CommandError {
            guard case .timedOut(executable: "sh", _) = error else { return XCTFail("unexpected \(error)") }
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    func testTimeoutReturnsEvenWhenAGrandchildHoldsThePipe() async throws {
        let start = Date()
        do {
            _ = try await runner.run(CommandRequest(executable: sh, arguments: ["-c", "sleep 30 & wait"], timeout: .milliseconds(300)))
            XCTFail("expected timeout")
        } catch is CommandError {}
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    func testMissingExecutableIsALaunchFailure() async throws {
        do {
            _ = try await runner.run(CommandRequest(executable: URL(fileURLWithPath: "/nonexistent/tool")))
            XCTFail("expected launchFailed")
        } catch let error as CommandError {
            guard case .launchFailed(executable: "tool", _) = error else { return XCTFail("unexpected \(error)") }
        }
    }

    func testCancellationStopsTheProcess() async throws {
        let request = CommandRequest(executable: sh, arguments: ["-c", "sleep 30"], timeout: .seconds(60))
        let task = Task { [runner] in
            try await runner.run(request)
        }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        let start = Date()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {}
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    func testDisplayStringQuotesOnlyWhenNeeded() {
        let request = CommandRequest(executable: URL(fileURLWithPath: "/opt/homebrew/bin/gh"), arguments: ["auth", "switch", "--user", "it's me"])
        XCTAssertEqual(request.displayString, "/opt/homebrew/bin/gh auth switch --user 'it'\\''s me'")
    }
}
