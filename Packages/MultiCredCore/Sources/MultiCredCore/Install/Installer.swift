import Foundation

public struct InstallOptions: Equatable, Sendable {
    public var shells: [ShellKind]
    public var removeLegacy: Bool

    public init(shells: [ShellKind], removeLegacy: Bool) {
        self.shells = shells
        self.removeLegacy = removeLegacy
    }
}

/// One file the user will see in "Revise antes de aplicar".
public struct FileChange: Equatable, Identifiable, Sendable {
    public enum Kind: String, Sendable { case create, modify, delete }

    public let path: String
    public let kind: Kind
    public let addedLines: [String]
    public let removedLines: [String]
    public var id: String { path }
}

/// What the installer did, kept so uninstall and later installs know.
public struct InstallManifest: VersionedDocument, Hashable {
    public static let currentVersion = 1

    public struct TouchedFile: Codable, Hashable, Sendable {
        public var path: String
        /// The file did not exist before MultiCred created it.
        public var createdByMultiCred: Bool
        /// Copy of the file before MultiCred first changed it.
        public var backup: String?
    }

    public var version: Int = Self.currentVersion
    public var installedAt: Date
    public var shells: [ShellKind]
    public var files: [TouchedFile]
}

public enum InstallError: Error, Equatable {
    case markerMismatch(path: String)
    case writeFailed(path: String, reason: String)
}

/// Adds MultiCred to the user's shells and git, transactionally.
///
/// ```
///  plan (read only) ──► preview ──► apply: backup originals ─► write each file
///                                                 │ failure: restore every file
///                                                 ▼          already written
///                                           manifest.json
/// ```
/// Running it again with the same options changes nothing (idempotent).
public struct Installer: Sendable {
    let environment: SystemEnvironment
    let paths: AppPaths

    public init(environment: SystemEnvironment) {
        self.environment = environment
        paths = AppPaths(environment: environment)
    }

    struct PlannedWrite {
        let target: URL
        let original: Data?
        let new: Data?
        let showInPreview: Bool
    }

    // MARK: Planning

    func plan(_ options: InstallOptions) throws -> [PlannedWrite] {
        var writes: [PlannedWrite] = []

        // Files inside the support directory (owned by MultiCred).
        for shell in ShellKind.allCases {
            let hook = paths.hook(shell)
            let wanted = options.shells.contains(shell) ? Data(ShellHookRenderer.render(shell).utf8) : nil
            writes.append(PlannedWrite(target: hook, original: try? Data(contentsOf: hook), new: wanted, showInPreview: false))
        }
        if !FileManager.default.fileExists(atPath: paths.gitconfig.path) {
            writes.append(PlannedWrite(target: paths.gitconfig, original: nil, new: Data(GitConfigRenderer.header.utf8), showInPreview: false))
        }

        // rc files: block for enabled shells, no block for the others.
        var rcTargets: [(URL, Bool)] = []
        for shell in ShellKind.allCases {
            for file in Integrations.rcFiles(for: shell, environment: environment) {
                rcTargets.append((file, options.shells.contains(shell)))
            }
        }
        for (file, enabled) in rcTargets {
            let shell = ShellKind.allCases.first { Integrations.rcFiles(for: $0, environment: environment).contains(file) }!
            if let write = try planBlock(in: file, body: enabled ? Integrations.rcBlock(for: shell) : nil, removeLegacy: options.removeLegacy) {
                writes.append(write)
            }
        }

        // fish: one whole file in conf.d.
        let fishFile = Integrations.fishConfFile(environment: environment)
        let fishOriginal = try? Data(contentsOf: fishFile)
        let fishWanted = options.shells.contains(.fish) ? Data(Integrations.fishConfContents().utf8) : nil
        if fishOriginal != fishWanted, fishWanted != nil || isOurs(fishOriginal) {
            writes.append(PlannedWrite(target: fishFile, original: fishOriginal, new: fishWanted, showInPreview: true))
        }

        // Global git config: include block at the very end.
        let git = Integrations.globalGitConfig(environment: environment)
        if let write = try planBlock(in: git, body: Integrations.gitIncludeBlock, removeLegacy: options.removeLegacy) {
            writes.append(write)
        }
        return writes.filter { $0.original != $0.new }
    }

    /// nil when the file needs no change. A missing file without a block to add stays missing.
    private func planBlock(in file: URL, body: String?, removeLegacy: Bool) throws -> PlannedWrite? {
        let target: URL
        do {
            target = try AtomicFileWriter.resolveTarget(file, followSymlink: true)
        } catch {
            throw InstallError.writeFailed(path: environment.abbreviate(file.path), reason: String(describing: error))
        }
        let original = try? Data(contentsOf: target)
        guard original != nil || body != nil else { return nil }
        var text = original.map { String(decoding: $0, as: UTF8.self) } ?? ""
        if removeLegacy { text = LegacyMigration.removeLegacyLines(from: text) }
        do {
            text = try body.map { try ManagedBlock.appendAtEnd($0, to: text) } ?? ManagedBlock.remove(from: text)
        } catch {
            throw InstallError.markerMismatch(path: environment.abbreviate(target.path))
        }
        let new = Data(text.utf8)
        return new == original ? nil : PlannedWrite(target: target, original: original, new: new, showInPreview: true)
    }

    private func isOurs(_ data: Data?) -> Bool {
        data.map { ManagedBlock.contains(String(decoding: $0, as: UTF8.self)) } ?? false
    }

    // MARK: Preview

    public func preview(_ options: InstallOptions) throws -> [FileChange] {
        try plan(options).filter(\.showInPreview).map { write in
            let before = write.original.map { String(decoding: $0, as: UTF8.self).components(separatedBy: "\n") } ?? []
            let after = write.new.map { String(decoding: $0, as: UTF8.self).components(separatedBy: "\n") } ?? []
            let kind: FileChange.Kind = write.new == nil ? .delete : (write.original == nil ? .create : .modify)
            let difference = after.difference(from: before)
            let added = difference.insertions.compactMap { if case let .insert(_, line, _) = $0 { return line } else { return nil } }
            let removed = difference.removals.compactMap { if case let .remove(_, line, _) = $0 { return line } else { return nil } }
            return FileChange(
                path: environment.abbreviate(write.target.path),
                kind: kind,
                addedLines: added.filter { !$0.isEmpty },
                removedLines: removed.filter { !$0.isEmpty }
            )
        }
    }

    // MARK: Apply

    @discardableResult
    public func apply(_ options: InstallOptions) throws -> InstallManifest {
        let writes = try plan(options)
        let stamp = Self.stamp(environment.clock())
        var manifest = (try? JSONFileStore<InstallManifest>(url: paths.manifest).load()) ?? nil
            ?? InstallManifest(installedAt: environment.clock(), shells: [], files: [])

        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var done: [PlannedWrite] = []
        do {
            for write in writes {
                if write.showInPreview, let original = write.original, !manifest.files.contains(where: { $0.path == write.target.path }) {
                    let backup = try backupCopy(original, of: write.target, stamp: stamp)
                    manifest.files.append(.init(path: write.target.path, createdByMultiCred: false, backup: backup.path))
                } else if write.showInPreview, write.original == nil, !manifest.files.contains(where: { $0.path == write.target.path }) {
                    manifest.files.append(.init(path: write.target.path, createdByMultiCred: true, backup: nil))
                }
                try perform(write.new, at: write.target)
                done.append(write)
            }
            manifest.shells = options.shells
            manifest.installedAt = environment.clock()
            try JSONFileStore<InstallManifest>(url: paths.manifest).save(manifest)
        } catch {
            for write in done.reversed() { try? perform(write.original, at: write.target) }
            throw InstallError.writeFailed(path: environment.abbreviate(done.last?.target.path ?? paths.root.path), reason: String(describing: error))
        }
        return manifest
    }

    func perform(_ data: Data?, at url: URL) throws {
        if let data {
            try AtomicFileWriter.write(data, to: url, permissions: 0o644, followSymlink: true)
        } else {
            try FileRestore.restore(nil, to: url)
        }
    }

    private func backupCopy(_ data: Data, of file: URL, stamp: String) throws -> URL {
        let name = environment.abbreviate(file.path)
            .replacingOccurrences(of: "~/", with: "")
            .replacingOccurrences(of: "/", with: "__")
        let destination = paths.backups.appendingPathComponent(stamp, isDirectory: true).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try AtomicFileWriter.write(data, to: destination, permissions: 0o600)
        return destination
    }

    static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter.string(from: date)
    }

    /// Installed means the manifest exists.
    public func manifest() -> InstallManifest? {
        (try? JSONFileStore<InstallManifest>(url: paths.manifest).load()) ?? nil
    }
}
