import Foundation
import XCTest
@testable import MultiCredCore

final class ToolLocatorTests: SafeTestCase {
    private func locator(_ directories: [String]) -> ToolLocator {
        ToolLocator(environment: environment, wellKnownDirectories: directories)
    }

    func testFindsToolInHomeLocalBin() async throws {
        runner.on("zsh", stdout: "")
        let claude = try makeExecutable(".local/bin/claude")
        let found = await locator(["~/.local/bin"]).locate(.claude)
        XCTAssertEqual(found?.path, claude.path)
    }

    func testWellKnownDirectoriesWinOverLoginShellPATH() async throws {
        let preferred = try makeExecutable("brew/bin/gh")
        let shadow = try makeExecutable("evil/bin/gh")
        runner.on("zsh", stdout: "__MULTICRED_PATH__\(shadow.deletingLastPathComponent().path):/usr/bin__MULTICRED_PATH__")
        let found = await locator([preferred.deletingLastPathComponent().path]).locate(.gh)
        XCTAssertEqual(found?.path, preferred.path)
    }

    func testFallsBackToLoginShellPATH() async throws {
        let npm = try makeExecutable("npm-global/bin/claude")
        runner.on("zsh", stdout: "banner from .zshrc\n__MULTICRED_PATH__/nowhere:\(npm.deletingLastPathComponent().path)__MULTICRED_PATH__\nbye")
        let found = await locator([home.appendingPathComponent("empty").path]).locate(.claude)
        XCTAssertEqual(found?.path, npm.path)
    }

    func testLoginShellIsRunAsLoginShellWithMinimalEnvironment() async throws {
        runner.on("zsh", stdout: "")
        _ = await locator([]).userLoginShellPATH()
        let request = try XCTUnwrap(runner.requests.first)
        XCTAssertEqual(request.executable.path, "/bin/zsh")
        XCTAssertEqual(Array(request.arguments.prefix(3)), ["-l", "-i", "-c"])
        XCTAssertNil(request.standardInput)
        XCTAssertEqual(request.environment["HOME"], home.path)
        XCTAssertEqual(request.environment["TERM"], "dumb")
        XCTAssertNil(request.environment["CLAUDE_CONFIG_DIR"])
    }

    func testLoginShellFailureOrTimeoutLeavesWellKnownDirectories() async throws {
        runner.on("zsh") { _ in throw CommandError.timedOut(executable: "zsh", seconds: 5) }
        let git = try makeExecutable("sys/bin/git")
        let found = await locator([git.deletingLastPathComponent().path]).locate(.git)
        XCTAssertEqual(found?.path, git.path)
    }

    func testLoginShellPATHIsCachedUntilInvalidated() async throws {
        runner.on("zsh", stdout: "__MULTICRED_PATH__/a__MULTICRED_PATH__")
        let locator = locator([])
        _ = await locator.userLoginShellPATH()
        _ = await locator.userLoginShellPATH()
        XCTAssertEqual(runner.requests.count, 1)
        await locator.invalidate()
        _ = await locator.userLoginShellPATH()
        XCTAssertEqual(runner.requests.count, 2)
    }

    func testMissingToolAndNonExecutableFiles() async throws {
        runner.on("zsh", stdout: "")
        let dir = home.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("gh"), withIntermediateDirectories: true)
        try Data().write(to: dir.appendingPathComponent("git")) // not executable
        let locator = locator([dir.path])
        let gh = await locator.locate(.gh)
        let git = await locator.locate(.git)
        XCTAssertNil(gh)
        XCTAssertNil(git)
    }

    func testSearchDirectoriesAreDeduplicatedAndTildeExpanded() async throws {
        runner.on("zsh", stdout: "__MULTICRED_PATH__/usr/bin:relative/dir:\(home.path)/.local/bin:/opt/x__MULTICRED_PATH__")
        let directories = await locator(["~/.local/bin", "/usr/bin"]).searchDirectories()
        XCTAssertEqual(directories, ["\(home.path)/.local/bin", "/usr/bin", "/opt/x"])
    }

    func testPathWithSpaces() {
        let parsed = ToolLocator.parseLoginShellOutput("__MULTICRED_PATH__/Users/a b/bin:/usr/bin__MULTICRED_PATH__")
        XCTAssertEqual(parsed, ["/Users/a b/bin", "/usr/bin"])
    }

    func testVersionReadsFirstLine() async throws {
        runner.on("zsh", stdout: "")
        try makeExecutable("bin/gh")
        runner.on("gh", ["--version"], stdout: "gh version 2.101.0 (2026-09-15)\nhttps://github.com/cli/cli/releases\n")
        let version = await locator([home.appendingPathComponent("bin").path]).version(of: .gh)
        XCTAssertEqual(version, "gh version 2.101.0 (2026-09-15)")
    }
}
