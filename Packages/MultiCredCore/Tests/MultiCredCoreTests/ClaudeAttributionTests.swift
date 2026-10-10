import XCTest
@testable import MultiCredCore

final class ClaudeAttributionTests: XCTestCase {
    private func json(_ data: Data?) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(data)) as? [String: Any])
    }

    func testOptOutWritesHiddenAttributionKeepingOtherSettings() throws {
        let current = Data(#"{"model":"opus","permissions":{"allow":["Bash(ls)"]}}"#.utf8)
        let updated = try json(ClaudeAttribution.updated(current, coAuthor: false))
        XCTAssertEqual(updated["attribution"] as? [String: String], ["commit": "", "pr": ""])
        XCTAssertEqual(updated["model"] as? String, "opus")
        XCTAssertNotNil(updated["permissions"])
    }

    func testOptOutOnMissingFileCreatesIt() throws {
        XCTAssertEqual(try json(ClaudeAttribution.updated(nil, coAuthor: false))["attribution"] as? [String: String], ClaudeAttribution.hidden)
    }

    func testNothingChangesWhenAlreadyInTheWantedState() throws {
        XCTAssertNil(try ClaudeAttribution.updated(Data(#"{"attribution":{"commit":"","pr":""}}"#.utf8), coAuthor: false))
        XCTAssertNil(try ClaudeAttribution.updated(Data(#"{"model":"opus"}"#.utf8), coAuthor: true))
        XCTAssertNil(try ClaudeAttribution.updated(nil, coAuthor: true))
    }

    func testOptInRemovesOnlyWhatMultiCredWrote() throws {
        let ours = try json(ClaudeAttribution.updated(Data(#"{"attribution":{"commit":"","pr":""},"model":"opus"}"#.utf8), coAuthor: true))
        XCTAssertNil(ours["attribution"])
        XCTAssertEqual(ours["model"] as? String, "opus")
        // Attribution text the user wrote by hand is theirs.
        XCTAssertNil(try ClaudeAttribution.updated(Data(#"{"attribution":{"commit":"Feito com IA"}}"#.utf8), coAuthor: true))
    }

    func testUnreadableSettingsAreLeftAlone() {
        XCTAssertThrowsError(try ClaudeAttribution.updated(Data("{not json".utf8), coAuthor: false)) {
            XCTAssertEqual($0 as? ClaudeAttribution.UpdateError, .unreadableSettings)
        }
    }

    func testOldConfigWithoutTheFieldKeepsCoAuthorOn() throws {
        let account = try JSONDecoder().decode(GitHubAccount.self, from: Data(#"{"id":"11111111-1111-1111-1111-111111111111","nickname":"P","username":"p","host":"github.com","color":"orange"}"#.utf8))
        XCTAssertTrue(account.claudeCoAuthor)
    }
}
