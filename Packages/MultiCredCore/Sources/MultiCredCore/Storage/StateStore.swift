import Foundation

/// `state.json` plus the `generation` file the shell hooks watch.
///
/// Write order matters: `state.json` first, `generation` last. Bumping the
/// generation is the commit point of a switch; shells only change after it.
public struct StateStore: Sendable {
    let paths: AppPaths
    let store: JSONFileStore<ActiveState>

    public init(paths: AppPaths, clock: @escaping @Sendable () -> Date = Date.init) {
        self.paths = paths
        self.store = JSONFileStore(url: paths.state, clock: clock)
    }

    /// A missing state file means nothing was ever applied.
    public func load() throws -> ActiveState {
        try store.load() ?? ActiveState()
    }

    public func commit(_ state: ActiveState) throws {
        try store.save(state)
        try AtomicFileWriter.write(Data("\(state.generation)\n".utf8), to: paths.generation, permissions: 0o644)
    }

    /// Raw snapshot of both files, for exact rollback.
    struct Snapshot: Sendable {
        let state: Data?
        let generation: Data?
    }

    func snapshot() -> Snapshot {
        Snapshot(state: try? Data(contentsOf: paths.state), generation: try? Data(contentsOf: paths.generation))
    }

    func restore(_ snapshot: Snapshot) throws {
        try FileRestore.restore(snapshot.generation, to: paths.generation)
        try FileRestore.restore(snapshot.state, to: paths.state, permissions: 0o600)
    }
}

enum FileRestore {
    /// Writes `data` back, or removes the file when it did not exist before.
    static func restore(_ data: Data?, to url: URL, permissions: Int = 0o644) throws {
        if let data {
            try AtomicFileWriter.write(data, to: url, permissions: permissions)
        } else if FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                throw FileWriteError.writeFailed(path: url.path, reason: error.localizedDescription)
            }
        }
    }
}
