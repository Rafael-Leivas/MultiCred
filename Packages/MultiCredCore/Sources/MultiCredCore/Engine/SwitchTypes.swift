import Foundation

/// Lets the engine find tools; `ToolLocator` in the app, a fake in tests.
public protocol ToolLocating: Sendable {
    func locate(_ tool: Tool) async -> URL?
    func searchDirectories() async -> [String]
}

extension ToolLocator: ToolLocating {}

/// Steps in the order they run. `state` is the commit point.
public enum SwitchStepKind: String, Sendable, CaseIterable, Codable {
    case git, github, launchd, claudeSettings, envFiles, state
}

public enum PreflightFailure: Error, Equatable, Sendable {
    case profileNotFound
    case claudeAccountNotFound
    case toolMissing(Tool)
    case claudeDirectoryMissing(String)
    case apiKeyMissing(nickname: String, envVar: String)
    /// The Claude account has no token in the Keychain.
    case claudeTokenMissing(String)
    /// Stored by an older build: shells would need the login password to read
    /// it and silently fall back to the folder's own login.
    case claudeTokenNeedsRefresh(String)
    case keychainUnavailable(String)
}

public enum RollbackOutcome: Equatable, Sendable {
    /// Everything done before the failure was undone.
    case complete
    /// These steps could not be undone; the system is inconsistent.
    case incomplete(failed: [SwitchStepKind])
}

public enum SwitchError: Error, Equatable, Sendable {
    /// Another switch is running.
    case busy
    case invalidConfiguration([ValidationIssue])
    case stateUnreadable(String)
    /// Nothing was changed.
    case preflight(PreflightFailure)
    case stepFailed(step: SwitchStepKind, reason: String, rollback: RollbackOutcome)
}

public struct SwitchResult: Equatable, Sendable {
    public let state: ActiveState
    public let claudeTarget: ClaudeTarget
    public let appliedSteps: [SwitchStepKind]
}

/// One reversible unit of work. `apply` returns the closure that undoes it.
struct SwitchStep: Sendable {
    typealias Undo = @Sendable () async throws -> Void

    let kind: SwitchStepKind
    let apply: @Sendable () async throws -> Undo
}
