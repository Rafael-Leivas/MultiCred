import Foundation

/// Loads and saves `config.json`. A missing file means "not configured yet".
public struct ConfigRepository: Sendable {
    private let store: JSONFileStore<Config>

    public init(environment: SystemEnvironment) {
        store = JSONFileStore(url: AppPaths(environment: environment).config, clock: environment.clock)
    }

    public func load() throws -> Config? {
        try store.load()
    }

    /// Refuses to save a configuration that could not be applied.
    public func save(_ config: Config) throws {
        let issues = Validation.issues(in: config)
        guard issues.isEmpty else { throw ClaudeAccountError.invalid(issues) }
        try store.save(config)
    }
}
