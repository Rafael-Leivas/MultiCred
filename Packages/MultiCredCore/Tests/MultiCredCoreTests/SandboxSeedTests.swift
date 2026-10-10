import Foundation
import XCTest
@testable import MultiCredCore

/// Opt-in helper for manual smoke tests of the Debug app: builds an installed
/// sandbox with a v1 config (accounts = folders) so the app migrates it on
/// launch. Runs only with MULTICRED_SEED_SANDBOX=<path inside the temp dir>.
final class SandboxSeedTests: XCTestCase {
    func testSeedSandbox() throws {
        guard let path = ProcessInfo.processInfo.environment["MULTICRED_SEED_SANDBOX"] else {
            throw XCTSkip("set MULTICRED_SEED_SANDBOX to seed a sandbox")
        }
        let home = URL(fileURLWithPath: path, isDirectory: true).resolvingSymlinksInPath()
        let temp = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().path
        let realHome = RealEnvironment.realHomeDirectory.resolvingSymlinksInPath().path
        precondition(home.path.hasPrefix(temp + "/") && home.path != realHome, "seed only inside the temp dir")

        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let environment = SystemEnvironment(mode: .test, home: home, loginShell: "/bin/zsh", userName: "tester",
                                            runner: FakeCommandRunner(), keychain: InMemoryKeychainStore())
        try Installer(environment: environment).apply(InstallOptions(shells: [.zsh], removeLegacy: false))

        for (name, email) in [(".claude", "trabalho@exemplo.com"), (".claude-pessoal", "pessoal@exemplo.com"), (".claude-dev-hinc", nil)] {
            let dir = home.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: dir.appendingPathComponent("projects/-Users-x-app"), withIntermediateDirectories: true)
            if let email {
                try Data(#"{"oauthAccount":{"emailAddress":"\#(email)"}}"#.utf8).write(to: ClaudeAccountFiles.stateFile(for: ClaudeFolder.ownLogin(name == ".claude" ? nil : dir.path), environment: environment))
            }
            let line = #"{"type":"custom-title","customTitle":"Conversa de \#(name)","cwd":"/Users/x/app"}"#
            try Data((line + "\n").utf8).write(to: dir.appendingPathComponent("projects/-Users-x-app/s1.jsonl"))
        }

        let v1 = #"""
        {"version":1,"gitIdentities":[
          {"id":"A1111111-1111-1111-1111-111111111111","nickname":"Trabalho","name":"Rafael","email":"trabalho@exemplo.com","color":"indigo"},
          {"id":"A2222222-2222-2222-2222-222222222222","nickname":"Pessoal","name":"Rafael","email":"pessoal@exemplo.com","color":"orange"}],
         "githubAccounts":[],"apiKeys":[],
         "claudeAccounts":[
          {"id":"11111111-1111-1111-1111-111111111111","nickname":"Pessoal","color":"orange","configDir":"\#(home.path)/.claude-pessoal"},
          {"id":"22222222-2222-2222-2222-222222222222","nickname":"Teste","color":"indigo"},
          {"id":"33333333-3333-3333-3333-333333333333","nickname":"DEV HINC","color":"teal","configDir":"\#(home.path)/.claude-dev-hinc"}],
         "profiles":[
          {"id":"B1111111-1111-1111-1111-111111111111","name":"Trabalho","color":"indigo","icon":{"letter":{"_0":"T"}},"gitIdentityId":"A1111111-1111-1111-1111-111111111111","claudeAccountId":"22222222-2222-2222-2222-222222222222","apiKeyIds":[]},
          {"id":"B2222222-2222-2222-2222-222222222222","name":"Pessoal","color":"orange","icon":{"letter":{"_0":"P"}},"gitIdentityId":"A2222222-2222-2222-2222-222222222222","claudeAccountId":"11111111-1111-1111-1111-111111111111","apiKeyIds":[]}],
         "settings":{"switchFeedback":"hud","enabledShells":["zsh"],"openAtLogin":false}}
        """#
        let paths = AppPaths(environment: environment)
        try Data(v1.utf8).write(to: paths.config)
    }
}
