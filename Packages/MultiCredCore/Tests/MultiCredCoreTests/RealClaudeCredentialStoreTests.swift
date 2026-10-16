import XCTest
@testable import MultiCredCore

/// Opt-in check of `SecurityClaudeCredentialStore` against the real login
/// keychain, with dummy entries only (a vault key and the item of a folder that
/// does not exist), all deleted at the end. Run with MULTICRED_REAL_CLAUDE_STORE=1.
final class RealClaudeCredentialStoreTests: XCTestCase {
    func testRoundTripWithDummyItems() throws {
        guard ProcessInfo.processInfo.environment["MULTICRED_REAL_CLAUDE_STORE"] == "1" else {
            throw XCTSkip("set MULTICRED_REAL_CLAUDE_STORE=1")
        }
        let store = SecurityClaudeCredentialStore(userName: NSUserName())
        let folder = "/tmp/multicred-dummy-folder-\(UUID().uuidString)"
        let key = "multicred-dummy-\(UUID().uuidString)"
        defer {
            try? store.deleteFolderItem(configDir: folder)
            try? store.deleteVault(key)
        }
        let value = Data(#"{"claudeAiOauth":{"accessToken":"dummy value with spaces"},"mcpOAuth":{}}"#.utf8)

        XCTAssertNil(try store.readFolderItem(configDir: folder))
        try store.writeFolderItem(configDir: folder, data: value)
        XCTAssertEqual(try store.readFolderItem(configDir: folder), value)
        try store.writeFolderItem(configDir: folder, data: Data("{}".utf8))
        XCTAssertEqual(try store.readFolderItem(configDir: folder), Data("{}".utf8), "-U updates in place")

        try store.writeVault(key, data: value)
        XCTAssertEqual(try store.readVault(key), value)
        try store.deleteVault(key)
        XCTAssertNil(try store.readVault(key))
        try store.deleteFolderItem(configDir: folder)
        XCTAssertNil(try store.readFolderItem(configDir: folder))
    }
}
