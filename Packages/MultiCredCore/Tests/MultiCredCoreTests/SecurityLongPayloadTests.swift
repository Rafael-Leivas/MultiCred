import XCTest
@testable import MultiCredCore

/// Regression for the 2026-11-14 freeze: a Claude Code credential item with a
/// large MCP login (Cloudflare scopes, ~7.7 KB) passed the `security -i` line
/// limit; `security` echoed the hex secret in "unknown command" errors, which
/// went raw into an alert taller than the screen and into the log.
final class SecurityLongPayloadTests: XCTestCase {
    private let service = "Claude Code-credentials-afe9af63"

    func testShortValuesStayOnStdin() {
        let command = SecurityToolCommand.add(service: service, account: "me", label: nil, secret: Data("small".utf8))
        XCTAssertEqual(command.arguments, ["-i"])
        XCTAssertNotNil(command.standardInput)
    }

    func testLongValuesGoInArgvInsteadOfOverflowingTheInteractiveLine() throws {
        let big = Data(String(repeating: "x", count: 8000).utf8)
        let command = SecurityToolCommand.add(service: service, account: "me", label: nil, secret: big)
        XCTAssertNil(command.standardInput)
        XCTAssertEqual(Array(command.arguments.prefix(7)), ["add-generic-password", "-U", "-s", service, "-a", "me", "-X"])
        XCTAssertEqual(command.arguments.last, SecurityToolRunner.hex(big))
    }

    func testTheLimitMatchesClaudeCode() {
        // Longest line that still fits: exactly at the limit stays on stdin.
        let overhead = SecurityToolRunner.interactiveLine(["add-generic-password", "-U", "-s", service, "-a", "me", "-X", ""]).utf8.count
        let fits = Data(repeating: 0x41, count: (SecurityToolCommand.interactiveLineLimit - overhead) / 2)
        XCTAssertEqual(SecurityToolCommand.add(service: service, account: "me", label: nil, secret: fits).arguments, ["-i"])
        let tooBig = Data(repeating: 0x41, count: fits.count + 1)
        XCTAssertNotEqual(SecurityToolCommand.add(service: service, account: "me", label: nil, secret: tooBig).arguments, ["-i"])
    }

    func testSecurityErrorsAreMaskedAndCapped() {
        let echoed = "security: unknown command \"" + String(repeating: "7b22616363657373546f6b656e223a22", count: 400) + "\""
        let result = CommandResult(exitCode: 1, standardError: Data(String(repeating: echoed + "\n", count: 8).utf8))
        let safe = SecurityToolRunner.sanitizedError(result)
        XCTAssertLessThanOrEqual(safe.count, 301)
        XCTAssertFalse(safe.contains("7b2261636365"))
        XCTAssertTrue(safe.hasPrefix("security: unknown command"))
    }

    func testAlertsNeverGetHugeOrShowHex() {
        let text = "Falhou em login da conta Claude na pasta (Keychain): securityFailed(\"" + String(repeating: "deadbeef", count: 4000) + "\")"
        let shown = Redactor.displayable(text)
        XCTAssertLessThanOrEqual(shown.count, 501)
        XCTAssertFalse(shown.contains("deadbeefdeadbeef"))
        XCTAssertTrue(shown.hasPrefix("Falhou em login da conta Claude"))
    }
}
