import XCTest
@testable import MultiCredCore

/// Regression for 2026-11-25: an old build cut a large ~/.claude credential item
/// at 2011 bytes while writing another account's login, then failed. The item
/// stayed cut off (with that other login) while MultiCred still believed the
/// previous account was there; every later switch failed with
/// unreadable("json").
final class DamagedFolderItemTests: SafeTestCase {
    /// Behaves like `security -i` before the fix: long values are written cut
    /// off, and the call then fails.
    private final class TruncatingStore: ClaudeCredentialStore, @unchecked Sendable {
        let inner = InMemoryClaudeCredentialStore()
        var limit = Int.max
        /// Cut off and fail only once, like a single failed `security` call.
        var failOnce = false
        func readFolderItem(configDir: String?) throws -> Data? { try inner.readFolderItem(configDir: configDir) }
        func writeFolderItem(configDir: String?, data: Data) throws {
            if failOnce, data.count > limit {
                failOnce = false
                try inner.writeFolderItem(configDir: configDir, data: data.prefix(limit))
                throw ClaudeLoginError.securityFailed("security: unknown command")
            }
            try inner.writeFolderItem(configDir: configDir, data: data)
        }
        func deleteFolderItem(configDir: String?) throws { try inner.deleteFolderItem(configDir: configDir) }
        func readVault(_ key: String) throws -> Data? { try inner.readVault(key) }
        func hasVaultEntry(_ key: String) throws -> Bool { try inner.readVault(key) != nil }
        func writeVault(_ key: String, data: Data) throws { try inner.writeVault(key, data: data) }
        func deleteVault(_ key: String) throws { try inner.deleteVault(key) }
    }

    private func json(_ object: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }
    private func oauth(_ name: String) -> [String: Any] { ["accessToken": "sk-ant-oat01-\(name)", "refreshToken": "sk-ant-ort01-\(name)"] }
    private func token(_ data: Data?) -> String? {
        ((try? JSONSerialization.jsonObject(with: data ?? Data())) as? [String: Any]).flatMap { ($0["claudeAiOauth"] as? [String: Any])?["accessToken"] as? String }
    }

    private var store: TruncatingStore!
    private var switcher: ClaudeLoginSwitcher!
    private let arvor = UUID(), marco = UUID()
    private let mcp: [String: Any] = [
        "hinc|1": ["accessToken": "mcp-1"],
        "hinc-http|2": ["accessToken": "mcp-2"],
        "plugin|3": ["accessToken": "mcp-3", "scope": String(repeating: "x", count: 3000)],
    ]

    override func setUpWithError() throws {
        try super.setUpWithError()
        store = TruncatingStore()
        switcher = ClaudeLoginSwitcher(environment: environment, store: store)
        try json(["oauthAccount": ["emailAddress": "own@x.com"]]).write(to: home.appendingPathComponent(".claude.json"))
        try store.writeFolderItem(configDir: nil, data: json(["claudeAiOauth": oauth("own"), "mcpOAuth": mcp]))
        try switcher.storeNewAccount(arvor, record: ClaudeLoginRecord(oauth: json(oauth("arvor")), account: json(["emailAddress": "arvor@x.com"])))
        try switcher.storeNewAccount(marco, record: ClaudeLoginRecord(oauth: json(oauth("marco")), account: json(["emailAddress": "marco@x.com"])))
        try switcher.place(arvor, in: nil)
    }

    func testSalvageKeepsCompleteMembersOfACutOffItem() throws {
        let full = json(["claudeAiOauth": oauth("marco"), "mcpOAuth": mcp])
        let cut = Array(full.prefix(full.count - 40))
        let salvaged = ClaudeLoginJSON.salvage(cut)
        XCTAssertEqual((salvaged["claudeAiOauth"] as? [String: Any])?["accessToken"] as? String, "sk-ant-oat01-marco")
        XCTAssertEqual((salvaged["mcpOAuth"] as? [String: Any]).map { Set($0.keys) }, ["hinc|1", "hinc-http|2"], "the cut-off MCP login is dropped, complete ones kept")
        XCTAssertFalse(ClaudeLoginJSON.folderItem(Data(cut)).intact)
    }

    func testAFailedCutOffWritePutsThePreviousItemBack() throws {
        let before = try store.readFolderItem(configDir: nil)
        store.limit = 2011
        store.failOnce = true
        XCTAssertThrowsError(try switcher.place(marco, in: nil))
        XCTAssertEqual(try store.readFolderItem(configDir: nil), before, "no cut-off item left behind")
        XCTAssertEqual(switcher.occupancy().account(in: nil), arvor)
    }

    /// The user's machine: the item is already cut off and holds another
    /// account's login, while MultiCred thinks Arvor is there.
    func testADamagedItemNeverOverwritesTheOwnersSavedLoginAndSwitchingRepairsIt() throws {
        let damaged = json(["claudeAiOauth": oauth("marco-live"), "mcpOAuth": mcp])
        try store.inner.writeFolderItem(configDir: nil, data: damaged.prefix(damaged.count - 40))
        let arvorBefore = try store.readVault(arvor.uuidString)

        try switcher.place(nil, in: nil)  // "Login da própria pasta"

        XCTAssertEqual(try store.readVault(arvor.uuidString), arvorBefore, "Arvor's saved login untouched")
        let repaired = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(store.readFolderItem(configDir: nil))) as? [String: Any])
        XCTAssertEqual(token(try store.readFolderItem(configDir: nil)), "sk-ant-oat01-own")
        XCTAssertEqual((repaired["mcpOAuth"] as? [String: Any]).map { Set($0.keys) }, ["hinc|1", "hinc-http|2"])
        XCTAssertNil(switcher.occupancy().account(in: nil))
    }
}
