import Foundation
import XCTest

/// Keeps the dependency-injection rule honest: only the files listed here may
/// reach the real user account or spawn processes directly.
final class ArchitectureGuardTests: XCTestCase {
    private static let forbidden = [
        "NSHomeDirectory",
        "homeDirectoryForCurrentUser",
        "ProcessInfo.processInfo.environment",
        "getpwuid",
        "NSUserName",
        "Process()",
        // launchd changes must go through the single adapter added in Phase 2.
        "/bin/launchctl",
    ]

    private static let allowed: [String: Set<String>] = [
        "Environment/RealEnvironment.swift": ["NSHomeDirectory", "getpwuid", "NSUserName"],
        "Commands/ProcessRunner.swift": ["Process()"],
        // Callers inject executable, arguments and the full environment.
        "Commands/PseudoTerminalProcess.swift": ["Process()"],
        "Adapters/Launchctl.swift": ["/bin/launchctl"],
    ]

    func testCoreDoesNotReachTheRealSystemOutsideAllowedFiles() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/MultiCredCore")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var violations: [String] = []
        var scanned = 0
        for case let file as URL in enumerator where file.pathExtension == "swift" {
            scanned += 1
            let relative = String(file.path.dropFirst(sources.path.count + 1))
            let text = try String(contentsOf: file, encoding: .utf8)
            for symbol in Self.forbidden where text.contains(symbol) {
                if Self.allowed[relative]?.contains(symbol) == true { continue }
                violations.append("\(relative): \(symbol)")
            }
        }
        XCTAssertGreaterThan(scanned, 5, "source scan found nothing; path is wrong")
        XCTAssertEqual(violations, [])
    }
}
