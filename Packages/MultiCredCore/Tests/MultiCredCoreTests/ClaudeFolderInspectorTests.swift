import Foundation
import XCTest
@testable import MultiCredCore

final class ClaudeFolderInspectorTests: SafeTestCase {
    private func session(_ folder: URL, project: String, name: String, lines: [String], modified: Date) throws {
        let dir = folder.appendingPathComponent("projects/\(project)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("\(name).jsonl")
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
    }

    func testSummarizesLoginProjectsAndRecentConversations() throws {
        let work = home.appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try Data(#"{"oauthAccount":{"emailAddress":"r@work.example","organizationName":"NPU"}}"#.utf8)
            .write(to: home.appendingPathComponent(".claude.json"))
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        let new = Date(timeIntervalSince1970: 1_790_000_000)
        try session(work, project: "-Users-x-npu-api", name: "a", lines: [
            #"{"type":"mode","mode":"x","sessionId":"a"}"#,
            #"{"type":"user","cwd":"\#(home.path)/npu/api","message":{"content":"secret message body"}}"#,
            #"{"type":"ai-title","aiTitle":"Corrigir deploy da API","sessionId":"a"}"#,
        ], modified: new)
        try session(work, project: "-Users-x-npu-web", name: "b", lines: [
            #"{"type":"user","cwd":"\#(home.path)/npu/web","message":{"content":"x"}}"#,
            #"{"type":"ai-title","aiTitle":"Título automático","sessionId":"b"}"#,
            #"{"type":"custom-title","customTitle":"Migração do login","sessionId":"b"}"#,
        ], modified: old)
        try session(work, project: "-Users-x-npu-web", name: "c", lines: [
            #"{"type":"last-prompt","lastPrompt":"ajuste o\nbotão","sessionId":"c"}"#,
        ], modified: old.addingTimeInterval(-10))

        let summary = ClaudeFolderInspector.summarize(configDir: nil, environment: environment)
        XCTAssertEqual(summary.email, "r@work.example")
        XCTAssertEqual(summary.organization, "NPU")
        XCTAssertEqual(summary.projectCount, 2)
        XCTAssertEqual(summary.conversationCount, 3)
        XCTAssertEqual(summary.lastActivity, new)
        XCTAssertEqual(summary.recentConversations.map(\.title), ["Corrigir deploy da API", "Migração do login", "ajuste o botão"])
        XCTAssertEqual(summary.recentConversations.first?.project, "~/npu/api")
        XCTAssertFalse(String(describing: summary).contains("secret message body"), "message bodies are never read into the summary")
    }

    func testEmptyAndLoggedOutFolders() throws {
        let dir = home.appendingPathComponent(".claude-novo", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let summary = ClaudeFolderInspector.summarize(configDir: dir.path, environment: environment)
        XCTAssertNil(summary.email)
        XCTAssertEqual(summary.conversationCount, 0)
        XCTAssertNil(summary.lastActivity)
        XCTAssertTrue(summary.exists)
    }

    /// Read-only check against the real Claude folders of this Mac. Prints only
    /// counts and the login e-mail. Opt-in: MULTICRED_INSPECT_REAL_CLAUDE=1
    func testRealFoldersReadOnly() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MULTICRED_INSPECT_REAL_CLAUDE"] == "1", "opt-in")
        let realHome = RealEnvironment.realHomeDirectory
        let real = SystemEnvironment(mode: .test, home: realHome, loginShell: "/bin/zsh", userName: "u",
                                     runner: FakeCommandRunner(), keychain: InMemoryKeychainStore())
        let folders = ClaudeFolderInspector.discoverFolders(environment: real)
        XCTAssertFalse(folders.isEmpty)
        for folder in folders {
            let summary = ClaudeFolderInspector.summarize(configDir: folder, environment: real)
            let titled = summary.recentConversations.filter { $0.title != "(sem título)" }.count
            print("REAL \(folder.map(real.abbreviate) ?? "~/.claude"): email=\(summary.email ?? "-") projects=\(summary.projectCount) conversations=\(summary.conversationCount) recentWithTitle=\(titled)/\(summary.recentConversations.count)")
        }
    }

    func testDiscoversDefaultAndNamedFolders() throws {
        for name in [".claude", ".claude-pessoal", ".claude-cliente"] {
            try FileManager.default.createDirectory(at: home.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        try Data("{}".utf8).write(to: home.appendingPathComponent(".claude.json"))
        XCTAssertEqual(ClaudeFolderInspector.discoverFolders(environment: environment),
                       [nil, home.path + "/.claude-cliente", home.path + "/.claude-pessoal"])
    }
}
