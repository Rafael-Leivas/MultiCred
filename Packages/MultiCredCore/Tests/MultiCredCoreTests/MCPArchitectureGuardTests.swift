import Foundation
import XCTest

/// The help server must stay read-only and offline. These symbols may not
/// appear in its sources; the runtime guards (`ReadOnlyCommandRunner`,
/// `PresenceOnlyKeychain`) are the second line of defence.
final class MCPArchitectureGuardTests: XCTestCase {
    private static let forbidden = [
        // network
        "import Network", "URLSession", "URLRequest(", "NWConnection", "CFSocket",
        // writes to disk
        "write(to:", "createFile", "removeItem", "createDirectory", "moveItem", "copyItem", "setAttributes",
        "AtomicFileWriter", "FileHandle(forWriting", "FileHandle(forUpdating",
        // switching, installing, logging in
        "SwitchEngine", "Installer(", "Uninstaller", "ConfigEditor", "LoginSession", "GitHubLoginFlow", "LoginFlow",
        "switchAccount", "runChecked", "Launchctl(", "setenv",
        // Keychain / credential access beyond presence
        "SecItemAdd", "SecItemUpdate", "SecItemDelete", "SecItemCopyMatching", "setSecret", "writeVault", "readVault",
        "writeFolderItem", "readFolderItem", "deleteVault", "deleteItem", "find-generic-password", "SecurityToolRunner",
        // processes outside the injected runner
        "Process()", "posix_spawn", "NSTask", "system(", "popen(",
        // real account outside RealEnvironment
        "NSHomeDirectory", "homeDirectoryForCurrentUser", "ProcessInfo.processInfo.environment",
    ]

    func testHelpTargetsUseNoWriteNetworkOrCredentialAPIs() throws {
        let packages = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var scanned = 0
        var violations: [String] = []
        for target in ["Sources/MultiCredHelp", "Sources/multicred-mcp"] {
            let root = packages.appendingPathComponent(target)
            let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
            for case let file as URL in enumerator where file.pathExtension == "swift" {
                scanned += 1
                let text = try String(contentsOf: file, encoding: .utf8)
                for symbol in Self.forbidden where text.contains(symbol) { violations.append("\(target)/\(file.lastPathComponent): \(symbol)") }
            }
        }
        XCTAssertGreaterThan(scanned, 5, "scan found nothing; path is wrong")
        XCTAssertEqual(violations, [])
    }

    func testHelpTargetDependsOnlyOnTheCore() throws {
        let manifest = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Package.swift")
        let text = try String(contentsOf: manifest, encoding: .utf8)
        XCTAssertFalse(text.contains(".package("), "no third-party package dependencies")
        XCTAssertFalse(text.contains("unsafeFlags"))
    }
}
