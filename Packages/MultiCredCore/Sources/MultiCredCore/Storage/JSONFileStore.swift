import Foundation

/// A Codable value persisted as JSON with a top-level `version` field.
public protocol VersionedDocument: Codable, Sendable {
    /// The version this build writes. Files with a higher version are never overwritten.
    static var currentVersion: Int { get }
    var version: Int { get }
}

public enum JSONStoreError: Error, Equatable, CustomStringConvertible {
    /// The file could not be decoded. It was moved aside so the user keeps a copy.
    case corrupt(movedTo: String, reason: String)
    /// Written by a newer MultiCred; left untouched.
    case unsupportedVersion(found: Int, supported: Int)
    case readFailed(path: String, reason: String)

    public var description: String {
        switch self {
        case let .corrupt(movedTo, reason): "Unreadable configuration (\(reason)); a copy was kept at \(movedTo)"
        case let .unsupportedVersion(found, supported): "Configuration version \(found) is newer than supported version \(supported)"
        case let .readFailed(path, reason): "Could not read \(path): \(reason)"
        }
    }
}

/// Loads and saves one JSON document. Files are 0600 inside a 0700 directory.
public struct JSONFileStore<Document: VersionedDocument>: Sendable {
    public let url: URL
    private let clock: @Sendable () -> Date

    public init(url: URL, clock: @escaping @Sendable () -> Date = Date.init) {
        self.url = url
        self.clock = clock
    }

    /// Returns nil when the file does not exist.
    public func load() throws -> Document? {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        } catch {
            throw JSONStoreError.readFailed(path: url.path, reason: error.localizedDescription)
        }

        let decoder = Self.decoder()
        if let probe = try? decoder.decode(VersionProbe.self, from: data), probe.version > Document.currentVersion {
            throw JSONStoreError.unsupportedVersion(found: probe.version, supported: Document.currentVersion)
        }
        do {
            return try decoder.decode(Document.self, from: data)
        } catch {
            let moved = try moveAside()
            throw JSONStoreError.corrupt(movedTo: moved.path, reason: String(describing: error))
        }
    }

    public func save(_ document: Document) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let data = try Self.encoder().encode(document)
        try AtomicFileWriter.write(data + Data("\n".utf8), to: url, permissions: 0o600)
    }

    private func moveAside() throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let destination = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).corrupt-\(formatter.string(from: clock()))")
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: url, to: destination)
        } catch {
            throw JSONStoreError.readFailed(path: url.path, reason: "corrupt and could not be moved aside: \(error.localizedDescription)")
        }
        return destination
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private struct VersionProbe: Decodable { let version: Int }
}
