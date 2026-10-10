import Foundation
import os

/// Append-only log in `~/Library/Logs/MultiCred/multicred.log` plus os.Logger.
///
/// Callers pass known secrets in `redacting`; they are replaced before anything
/// is written. Rotation keeps `multicred.log` plus `.1` and `.2`, each up to
/// `maxBytes`.
public final class EventLog: @unchecked Sendable {
    public enum Level: String, Sendable { case info, warning, error }

    private let directory: URL
    private let maxBytes: Int
    private let clock: @Sendable () -> Date
    private let lock = NSLock()
    private let logger = Logger(subsystem: "app.multicred", category: "events")

    public init(directory: URL, maxBytes: Int = 1_000_000, clock: @escaping @Sendable () -> Date = Date.init) {
        self.directory = directory
        self.maxBytes = maxBytes
        self.clock = clock
    }

    public var currentFile: URL { directory.appendingPathComponent("multicred.log") }

    public func log(_ level: Level, _ message: String, redacting secrets: [String] = []) {
        let clean = Redactor.redact(message, secrets: secrets)
        switch level {
        case .info: logger.info("\(clean, privacy: .public)")
        case .warning: logger.warning("\(clean, privacy: .public)")
        case .error: logger.error("\(clean, privacy: .public)")
        }
        let stamp = ISO8601DateFormatter().string(from: clock())
        let line = "\(stamp) [\(level.rawValue)] \(clean.replacingOccurrences(of: "\n", with: "\\n"))\n"
        lock.lock(); defer { lock.unlock() }
        append(Data(line.utf8))
    }

    /// Last `count` lines across the current file, for "Copy diagnostics".
    public func tail(_ count: Int) -> [String] {
        lock.lock(); defer { lock.unlock() }
        guard let text = try? String(contentsOf: currentFile, encoding: .utf8) else { return [] }
        return Array(text.split(separator: "\n", omittingEmptySubsequences: true).suffix(count).map(String.init))
    }

    private func append(_ data: Data) {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        if let size = (try? fm.attributesOfItem(atPath: currentFile.path)[.size]) as? Int, size + data.count > maxBytes {
            rotate()
        }
        if !fm.fileExists(atPath: currentFile.path) {
            fm.createFile(atPath: currentFile.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let handle = try? FileHandle(forWritingTo: currentFile) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }

    private func rotate() {
        let fm = FileManager.default
        let one = directory.appendingPathComponent("multicred.log.1")
        let two = directory.appendingPathComponent("multicred.log.2")
        try? fm.removeItem(at: two)
        try? fm.moveItem(at: one, to: two)
        try? fm.moveItem(at: currentFile, to: one)
    }
}

public enum Redactor {
    public static let mask = "••••"

    /// Replaces every occurrence of each non-empty secret with a mask.
    public static func redact(_ text: String, secrets: [String]) -> String {
        secrets
            .filter { !$0.isEmpty }
            .sorted { $0.count > $1.count }
            .reduce(text) { $0.replacingOccurrences(of: $1, with: mask) }
    }

    /// For diagnostics of CLI output: also masks anything that looks like a
    /// credential (sk-ant-… or any run of 40+ token characters), so an
    /// unexpected token format never reaches a log.
    public static func redactCredentialLike(_ text: String, secrets: [String] = []) -> String {
        redact(text, secrets: secrets)
            .replacingOccurrences(of: #"sk-ant-[A-Za-z0-9_\-]+"#, with: mask, options: .regularExpression)
            .replacingOccurrences(of: #"[A-Za-z0-9_\-#]{40,}"#, with: mask, options: .regularExpression)
    }
}
