import Foundation

/// Records commands instead of running them. Used by the app's test mode so the UI
/// can be exercised without touching git, gh, Claude Code or launchd.
///
/// `responder` lets the caller fake specific outputs (for example a plausible
/// `gh auth status`); anything it does not handle succeeds with empty output.
public actor DryRunCommandRunner: CommandRunner {
    public struct Entry: Sendable, Equatable {
        public let date: Date
        public let command: String
    }

    public typealias Responder = @Sendable (CommandRequest) -> CommandResult?

    private let responder: Responder?
    private let clock: @Sendable () -> Date
    private(set) public var entries: [Entry] = []

    public init(clock: @escaping @Sendable () -> Date = Date.init, responder: Responder? = nil) {
        self.clock = clock
        self.responder = responder
    }

    public func run(_ request: CommandRequest) async throws -> CommandResult {
        entries.append(Entry(date: clock(), command: request.displayString))
        return responder?(request) ?? CommandResult(exitCode: 0)
    }
}
