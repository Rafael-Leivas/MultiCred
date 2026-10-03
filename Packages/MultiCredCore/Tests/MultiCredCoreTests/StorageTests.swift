import Foundation
import XCTest
@testable import MultiCredCore

private struct SampleDocument: VersionedDocument, Equatable {
    static let currentVersion = 1
    var version = SampleDocument.currentVersion
    var name: String
    var updatedAt: Date
}

final class AtomicFileWriterTests: SafeTestCase {
    func testCreatesFileWithRequestedPermissions() throws {
        let url = home.appendingPathComponent("a/b/file.txt")
        try AtomicFileWriter.write(Data("one".utf8), to: url, permissions: 0o600)
        XCTAssertEqual(try read(url), "one")
        XCTAssertEqual(try mode(of: url), 0o600)
    }

    func testReplacingKeepsExistingPermissionsAndLeavesNoTempFiles() throws {
        let url = home.appendingPathComponent("rc")
        try Data("old".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: url.path)
        try AtomicFileWriter.write(Data("new".utf8), to: url, permissions: 0o600)
        XCTAssertEqual(try read(url), "new")
        XCTAssertEqual(try mode(of: url), 0o640)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: home.path).filter { $0.contains("multicred-") }
        XCTAssertEqual(leftovers, [])
    }

    func testRefusesSymlinkUnlessAskedToFollow() throws {
        let real = home.appendingPathComponent("dotfiles/zshrc")
        try FileManager.default.createDirectory(at: real.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("real".utf8).write(to: real)
        let link = home.appendingPathComponent(".zshrc")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        XCTAssertThrowsError(try AtomicFileWriter.write(Data("x".utf8), to: link)) { error in
            guard case FileWriteError.unsafeTarget = error else { return XCTFail("\(error)") }
        }

        let written = try AtomicFileWriter.write(Data("edited".utf8), to: link, followSymlink: true)
        XCTAssertEqual(written.path, real.resolvingSymlinksInPath().path)
        XCTAssertEqual(try read(real), "edited")
        let attributes = try FileManager.default.attributesOfItem(atPath: link.path)
        XCTAssertEqual(attributes[.type] as? FileAttributeType, .typeSymbolicLink, "the link itself must survive")
    }

    func testRefusesBrokenSymlinkAndDirectories() throws {
        let link = home.appendingPathComponent(".bashrc")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: home.appendingPathComponent("missing").path)
        XCTAssertThrowsError(try AtomicFileWriter.write(Data("x".utf8), to: link, followSymlink: true))

        let directory = home.appendingPathComponent("dir")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        XCTAssertThrowsError(try AtomicFileWriter.write(Data("x".utf8), to: directory))
    }
}

final class JSONFileStoreTests: SafeTestCase {
    private var url: URL { environment.appSupportDirectory.appendingPathComponent("config.json") }
    private var store: JSONFileStore<SampleDocument> { JSONFileStore(url: url, clock: environment.clock) }

    func testMissingFileLoadsAsNil() throws {
        XCTAssertNil(try store.load())
    }

    func testRoundTripWithPrivatePermissions() throws {
        let document = SampleDocument(name: "Trabalho \"NPU\" — ç", updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
        try store.save(document)
        XCTAssertEqual(try store.load(), document)
        XCTAssertEqual(try mode(of: url), 0o600)
        XCTAssertEqual(try mode(of: environment.appSupportDirectory), 0o700)
    }

    func testCorruptFileIsMovedAsideAndReported() throws {
        try FileManager.default.createDirectory(at: environment.appSupportDirectory, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: url)
        XCTAssertThrowsError(try store.load()) { error in
            guard case let JSONStoreError.corrupt(movedTo, _) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(FileManager.default.fileExists(atPath: movedTo))
            XCTAssertTrue(movedTo.hasSuffix("config.json.corrupt-20260921-112640") || movedTo.contains("config.json.corrupt-"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testNewerVersionIsNeverOverwrittenOrMoved() throws {
        try FileManager.default.createDirectory(at: environment.appSupportDirectory, withIntermediateDirectories: true)
        let newer = #"{"version": 2, "name": "x", "updatedAt": "2026-10-02T00:00:00Z", "future": true}"#
        try Data(newer.utf8).write(to: url)
        XCTAssertThrowsError(try store.load()) { error in
            XCTAssertEqual(error as? JSONStoreError, .unsupportedVersion(found: 2, supported: 1))
        }
        XCTAssertEqual(try read(url), newer)
    }
}

final class KeychainStoreTests: XCTestCase {
    func testInMemoryStoreContract() throws {
        let store = InMemoryKeychainStore()
        let account = UUID().uuidString
        XCTAssertFalse(try store.containsItem(account: account))
        try store.setSecret(Data("sk-1".utf8), account: account)
        try store.setSecret(Data("sk-2".utf8), account: account)
        XCTAssertTrue(try store.containsItem(account: account))
        XCTAssertEqual(store.storedValue(account: account), Data("sk-2".utf8))
        XCTAssertEqual(try store.allAccounts(), [account])
        try store.deleteItem(account: account)
        try store.deleteItem(account: account)
        XCTAssertEqual(try store.allAccounts(), [])
    }

    func testRejectsEmptySecretsAndNonUUIDAccounts() {
        let store = InMemoryKeychainStore()
        XCTAssertThrowsError(try store.setSecret(Data(), account: UUID().uuidString)) {
            XCTAssertEqual($0 as? KeychainError, .emptySecret)
        }
        XCTAssertThrowsError(try store.setSecret(Data("x".utf8), account: "x; rm -rf ~")) {
            XCTAssertEqual($0 as? KeychainError, .invalidAccount("x; rm -rf ~"))
        }
    }

    /// Touches the real login keychain. Runs only when explicitly allowed:
    /// `MULTICRED_ALLOW_REAL_KEYCHAIN=1 swift test --filter KeychainStoreTests`
    func testRealKeychainRoundTrip() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MULTICRED_ALLOW_REAL_KEYCHAIN"] == "1", "real keychain test not authorized")
        let store = SecItemKeychainStore(service: "app.multicred.tests.\(UUID().uuidString)")
        let account = UUID().uuidString
        defer { try? store.deleteItem(account: account) }
        try store.setSecret(Data("value".utf8), account: account)
        XCTAssertTrue(try store.containsItem(account: account))
        XCTAssertEqual(try store.allAccounts(), [account])
        try store.deleteItem(account: account)
        XCTAssertFalse(try store.containsItem(account: account))
    }
}
