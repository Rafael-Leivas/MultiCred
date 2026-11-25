import XCTest
@testable import MultiCredCore

/// Opt-in, read-only: how the salvage reads the real ~/.claude credential item.
/// Prints member names only. Run with MULTICRED_PROBE_DAMAGED_ITEM=1.
final class RealDamagedItemProbeTests: XCTestCase {
    func testSalvageOfTheRealDefaultFolderItem() throws {
        guard ProcessInfo.processInfo.environment["MULTICRED_PROBE_DAMAGED_ITEM"] == "1" else {
            throw XCTSkip("set MULTICRED_PROBE_DAMAGED_ITEM=1")
        }
        let item = try SecurityClaudeCredentialStore(userName: NSUserName()).readFolderItem(configDir: nil)
        let (object, intact) = ClaudeLoginJSON.folderItem(item)
        print("PROBE intact=\(intact) keys=\(object.keys.sorted())")
        print("PROBE claudeAiOauth complete=\((object["claudeAiOauth"] as? [String: Any])?["refreshToken"] != nil)")
        print("PROBE mcpOAuth servers=\(((object["mcpOAuth"] as? [String: Any]) ?? [:]).keys.map { $0.split(separator: "|").first.map(String.init) ?? "" }.sorted())")
    }
}
