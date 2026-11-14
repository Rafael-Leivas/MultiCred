import Foundation
import XCTest

/// The guide and the MCP tools go stale silently unless whoever changes the app
/// is asked. This keeps the question in the files people (and Claude) read first.
final class MaintenanceRuleTests: XCTestCase {
    static let question = "Deseja atualizar as tools do MCP (e o guia) para refletir esta mudança?"

    func testRuleSentencePresentInAllMarkdownFiles() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        for file in ["CLAUDE.md", "CONTRIBUTING.md", "docs/PLAN.md", "Packages/MultiCredCore/Sources/MultiCredHelp/Guide/guia.md"] {
            let text = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            XCTAssertTrue(text.contains(Self.question), "\(file) lost the maintenance rule: \"\(Self.question)\"")
        }
    }
}
