import Foundation
import XCTest
@testable import MultiCredCore

final class SystemEnvironmentTests: SafeTestCase {
    func testDirectoriesDeriveFromInjectedHome() {
        XCTAssertEqual(environment.appSupportDirectory.path, home.path + "/Library/Application Support/MultiCred")
        XCTAssertEqual(environment.logsDirectory.path, home.path + "/Library/Logs/MultiCred")
    }

    func testTildeExpansionAndAbbreviation() {
        XCTAssertEqual(environment.expandTilde("~"), home.path)
        XCTAssertEqual(environment.expandTilde("~/.claude-x"), home.path + "/.claude-x")
        XCTAssertEqual(environment.expandTilde("~other/x"), "~other/x")
        XCTAssertEqual(environment.expandTilde("/abs"), "/abs")
        XCTAssertEqual(environment.abbreviate(home.path + "/.claude"), "~/.claude")
        XCTAssertEqual(environment.abbreviate(home.path + "x/y"), home.path + "x/y")
    }

    func testChildEnvironmentIsMinimal() {
        let env = environment.baseProcessEnvironment(path: ["/a", "/b"])
        XCTAssertEqual(env["PATH"], "/a:/b")
        XCTAssertEqual(env["HOME"], home.path)
        XCTAssertEqual(Set(env.keys), ["HOME", "USER", "LOGNAME", "SHELL", "PATH", "LANG"])
    }

    func testDryRunRunnerRecordsWithoutExecuting() async throws {
        let marker = home.appendingPathComponent("must-not-exist")
        let runner = DryRunCommandRunner(clock: environment.clock)
        let result = try await runner.run(CommandRequest(executable: URL(fileURLWithPath: "/usr/bin/touch"), arguments: [marker.path]))
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        let entries = await runner.entries
        XCTAssertEqual(entries.map(\.command), ["/usr/bin/touch \(marker.path)"])
    }
}

final class ShellQuotingTests: XCTestCase {
    func testPosixSingleQuotes() {
        XCTAssertEqual(ShellQuoting.singleQuoted("/Users/a b/.claude"), "'/Users/a b/.claude'")
        XCTAssertEqual(ShellQuoting.singleQuoted("it's"), "'it'\\''s'")
        XCTAssertEqual(ShellQuoting.singleQuoted("$(id) `id` \\n"), "'$(id) `id` \\n'")
    }

    func testFishSingleQuotes() {
        XCTAssertEqual(ShellQuoting.fishSingleQuoted("it's \\ ok"), "'it\\'s \\\\ ok'")
    }

    /// The quoted value must come back byte-for-byte from a real POSIX shell.
    func testPosixQuotingRoundTripsThroughSh() async throws {
        let nasty = "a'b\"c$(id)`id`\\n é 🚀 ;|&"
        let result = try await ProcessRunner().run(CommandRequest(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf '%s' \(ShellQuoting.singleQuoted(nasty))"]
        ))
        XCTAssertEqual(result.stdout, nasty)
    }
}

final class EventLogTests: SafeTestCase {
    func testWritesRedactedLinesPrivately() throws {
        let log = EventLog(directory: environment.logsDirectory, clock: environment.clock)
        log.log(.info, "pasted code ABC123 for account", redacting: ["ABC123"])
        let text = try read(log.currentFile)
        XCTAssertTrue(text.contains("[info] pasted code •••• for account"))
        XCTAssertFalse(text.contains("ABC123"))
        XCTAssertEqual(try mode(of: log.currentFile), 0o600)
    }

    func testNewlinesCannotForgeLogLines() throws {
        let log = EventLog(directory: environment.logsDirectory, clock: environment.clock)
        log.log(.info, "name\n2026-01-01T00:00:00Z [error] forged")
        XCTAssertEqual(log.tail(10).count, 1)
    }

    func testRotatesAtSizeLimit() throws {
        let log = EventLog(directory: environment.logsDirectory, maxBytes: 200, clock: environment.clock)
        for index in 0..<30 { log.log(.info, "line \(index) with some padding") }
        let files = try FileManager.default.contentsOfDirectory(atPath: environment.logsDirectory.path).sorted()
        XCTAssertEqual(files, ["multicred.log", "multicred.log.1", "multicred.log.2"])
        XCTAssertTrue(log.tail(1).first?.hasSuffix("line 29 with some padding") ?? false)
    }

    func testRedactorMasksLongestFirst() {
        XCTAssertEqual(Redactor.redact("abc abcdef", secrets: ["abc", "abcdef", ""]), "•••• ••••")
    }
}
