import Foundation

/// Loads and saves `config.json`. A missing file means "not configured yet".
/// Older versions are migrated on load (a copy of the old file is kept as
/// `config.json.v<version>`) and saved back.
public struct ConfigRepository: Sendable {
    private let store: JSONFileStore<Config>
    private let url: URL

    public init(environment: SystemEnvironment) {
        url = AppPaths(environment: environment).config
        store = JSONFileStore(url: url, clock: environment.clock)
    }

    public func load() throws -> Config? {
        guard let loaded = try store.load() else { return nil }
        let (migrated, changed) = ConfigMigration.migrate(loaded)
        if changed {
            let backup = url.deletingLastPathComponent().appendingPathComponent("config.json.v\(loaded.version)")
            if !FileManager.default.fileExists(atPath: backup.path) {
                try? FileManager.default.copyItem(at: url, to: backup)
            }
            try save(migrated)
        }
        return migrated
    }

    /// Refuses to save a configuration that could not be applied.
    public func save(_ config: Config) throws {
        let issues = Validation.issues(in: config)
        guard issues.isEmpty else { throw ClaudeAccountError.invalid(issues) }
        try store.save(config)
    }
}
