import Foundation
import XCTest
@testable import MultiCredCore

final class ConnectCommandTests: SafeTestCase {
    func testCommandPerAccountQuotesPathsAndDefaultHasNoVariable() throws {
        let personal = home.path + "/.claude-pessoal"
        let marco = home.path + "/.claude marco"
        var config = Config()
        config.profiles = [
            Profile(name: "Trabalho", color: .indigo, claudeConfigDir: nil),
            Profile(name: "Pessoal", color: .orange, claudeConfigDir: personal),
            Profile(name: "Outro", color: .teal, claudeConfigDir: personal),
        ]
        config.claudeAccounts = [ClaudeAccount(nickname: "Marco", color: .teal, kind: .login, configDir: marco)]
        let executable = URL(fileURLWithPath: "/Applications/Multi Cred.app/Contents/Helpers/multicred-mcp")

        let targets = ClaudeHelpConnection.targets(config: config, executable: executable, environment: environment)

        XCTAssertEqual(targets.map(\.configDir), [nil, marco, personal].sorted { ($0 ?? "") < ($1 ?? "") }, "default first, no duplicates, sorted")
        let bin = "'/Applications/Multi Cred.app/Contents/Helpers/multicred-mcp'"
        XCTAssertEqual(targets[0].label, "Conta padrão (~/.claude)")
        XCTAssertEqual(targets[0].command, "claude mcp add --scope user multicred -- \(bin)")
        XCTAssertEqual(targets[1].label, "~/.claude marco")
        XCTAssertEqual(targets[1].command, "CLAUDE_CONFIG_DIR='\(marco)' claude mcp add --scope user multicred -- \(bin)")
        XCTAssertEqual(targets[2].command, "CLAUDE_CONFIG_DIR=\(personal) claude mcp add --scope user multicred -- \(bin)", "quoted only when needed")
        XCTAssertEqual(targets[0].removeCommand, "claude mcp remove multicred --scope user")
        XCTAssertEqual(targets[2].removeCommand, "CLAUDE_CONFIG_DIR=\(personal) claude mcp remove multicred --scope user")
    }

    func testNoProfilesStillOffersTheDefaultFolder() {
        let targets = ClaudeHelpConnection.targets(config: Config(), executable: URL(fileURLWithPath: "/a/multicred-mcp"), environment: environment)
        XCTAssertEqual(targets.map(\.configDir), [nil])
        XCTAssertEqual(targets[0].command, "claude mcp add --scope user multicred -- /a/multicred-mcp")
    }

    func testApostropheInPathIsEscaped() {
        let targets = ClaudeHelpConnection.targets(config: Config(), executable: URL(fileURLWithPath: "/Users/o'neil/MultiCred.app/Contents/Helpers/multicred-mcp"), environment: environment)
        XCTAssertEqual(targets[0].command, "claude mcp add --scope user multicred -- '/Users/o'\\''neil/MultiCred.app/Contents/Helpers/multicred-mcp'")
    }

    func testEquivalentPathsCollapseAndAppLocationIsChecked() {
        var config = Config()
        config.profiles = [
            Profile(name: "A", color: .indigo, claudeConfigDir: home.path + "/.claude-x"),
            Profile(name: "B", color: .orange, claudeConfigDir: home.path + "/.claude-x/"),
            Profile(name: "C", color: .teal, claudeConfigDir: home.path + "/.claude"),
        ]
        let targets = ClaudeHelpConnection.targets(config: config, executable: URL(fileURLWithPath: "/Applications/MultiCred.app/Contents/Helpers/multicred-mcp"), environment: environment)
        XCTAssertEqual(targets.map(\.configDir), [nil, home.path + "/.claude-x"], "trailing slash and the default folder collapse")

        func warning(_ path: String) -> String? {
            ClaudeHelpConnection.locationWarning(executable: URL(fileURLWithPath: path), environment: environment)
        }
        XCTAssertNil(warning("/Applications/MultiCred.app/Contents/Helpers/multicred-mcp"))
        XCTAssertNil(warning(home.path + "/Applications/MultiCred.app/Contents/Helpers/multicred-mcp"))
        XCTAssertNotNil(warning("/private/var/folders/ab/T/AppTranslocation/X/d/MultiCred.app/Contents/Helpers/multicred-mcp"))
        XCTAssertNotNil(warning(home.path + "/Downloads/MultiCred.app/Contents/Helpers/multicred-mcp"))
        XCTAssertNotNil(warning(home.path + "/Library/Developer/Xcode/DerivedData/x/Build/Products/Debug/MultiCred.app/Contents/Helpers/multicred-mcp"))
    }
}
