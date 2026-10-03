import Foundation

public enum FileWriteError: Error, Equatable, CustomStringConvertible {
    case writeFailed(path: String, reason: String)
    case unsafeTarget(path: String, reason: String)

    public var description: String {
        switch self {
        case let .writeFailed(path, reason): "Could not write \(path): \(reason)"
        case let .unsafeTarget(path, reason): "Refusing to write \(path): \(reason)"
        }
    }
}

/// Writes files atomically: temp file in the same directory, fsync, rename.
/// A crash mid-write leaves either the old file or the new one, never a mix.
public enum AtomicFileWriter {
    /// - Parameters:
    ///   - permissions: POSIX mode for a new file. An existing file keeps its mode.
    ///   - followSymlink: when the target is a symlink (dotfile managers such as
    ///     stow or chezmoi), write to its destination instead of replacing the link.
    ///     The destination must be a regular file or missing.
    /// - Returns: the path that was actually written.
    @discardableResult
    public static func write(
        _ data: Data,
        to url: URL,
        permissions: Int = 0o644,
        followSymlink: Bool = false
    ) throws -> URL {
        let target = try resolveTarget(url, followSymlink: followSymlink)
        let fm = FileManager.default
        let directory = target.deletingLastPathComponent()

        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw FileWriteError.writeFailed(path: directory.path, reason: error.localizedDescription)
        }

        var mode = mode_t(permissions)
        var info = stat()
        if lstat(target.path, &info) == 0 {
            mode = info.st_mode & 0o7777
        }

        let temp = directory.appendingPathComponent(".\(target.lastPathComponent).multicred-\(UUID().uuidString)")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL, mode)
        guard fd >= 0 else {
            throw FileWriteError.writeFailed(path: target.path, reason: String(cString: strerror(errno)))
        }
        var failure: String?
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    failure = String(cString: strerror(errno))
                    return
                }
                offset += written
            }
        }
        if failure == nil, fchmod(fd, mode) != 0 { failure = String(cString: strerror(errno)) }
        if failure == nil, fsync(fd) != 0 { failure = String(cString: strerror(errno)) }
        close(fd)

        if failure == nil, rename(temp.path, target.path) != 0 {
            failure = String(cString: strerror(errno))
        }
        if let failure {
            unlink(temp.path)
            throw FileWriteError.writeFailed(path: target.path, reason: failure)
        }
        return target
    }

    /// Resolves the file that a write to `url` would change, applying the same
    /// symlink policy as `write`.
    public static func resolveTarget(_ url: URL, followSymlink: Bool) throws -> URL {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return url }
        let type = info.st_mode & S_IFMT
        if type == S_IFREG { return url }
        guard type == S_IFLNK else {
            throw FileWriteError.unsafeTarget(path: url.path, reason: "not a regular file")
        }
        guard followSymlink else {
            throw FileWriteError.unsafeTarget(path: url.path, reason: "is a symbolic link")
        }
        let destination = url.resolvingSymlinksInPath()
        var destinationInfo = stat()
        if lstat(destination.path, &destinationInfo) != 0 {
            throw FileWriteError.unsafeTarget(path: url.path, reason: "symbolic link points to a missing file")
        }
        guard destinationInfo.st_mode & S_IFMT == S_IFREG else {
            throw FileWriteError.unsafeTarget(path: url.path, reason: "symbolic link does not point to a regular file")
        }
        return destination
    }
}
