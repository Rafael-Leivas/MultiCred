import Foundation

/// What `gh auth login --web` says (gh 2.x):
///
/// ```
/// ! First copy your one-time code: 1A2B-3C4D
/// Press Enter to open https://github.com/login/device in your browser...
/// ✓ Authentication complete.
/// ✓ Logged in as octocat
/// ```
/// It may also ask yes/no questions (for example whether to set up git
/// credentials); those are answered with the default, "yes".
public enum GitHubLoginEvent: Equatable, Sendable {
    case oneTimeCode(String)
    case pressEnterToOpenBrowser
    case question(String)
    case succeeded(login: String?)
    case failed(String)
}

public struct GitHubLoginParser: Sendable {
    private var pending = ""
    private var emitted = Set<String>()
    private var login: String?
    private var completed = false
    public private(set) var transcript = ""

    public init() {}

    public mutating func consume(_ bytes: some Sequence<UInt8>) -> [GitHubLoginEvent] {
        let text = LoginOutputParser.stripEscapes(String(decoding: Array(bytes), as: UTF8.self))
        transcript += text
        pending += text
        var events: [GitHubLoginEvent] = []
        while let newline = pending.firstIndex(where: \.isNewline) {
            let line = String(pending[..<newline])
            pending.removeSubrange(...newline)
            events += classify(line, partial: false)
        }
        events += classify(pending, partial: true)
        return events
    }

    private mutating func classify(_ raw: String, partial: Bool) -> [GitHubLoginEvent] {
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return [] }
        let lower = line.lowercased()
        var events: [GitHubLoginEvent] = []
        func once(_ key: String, _ event: GitHubLoginEvent) {
            if emitted.insert(key).inserted { events.append(event) }
        }

        if lower.contains("one-time code"),
           let range = line.range(of: #"[A-Z0-9]{4}-[A-Z0-9]{4}"#, options: .regularExpression) {
            once("code", .oneTimeCode(String(line[range])))
        }
        if lower.contains("press enter") { once("enter", .pressEnterToOpenBrowser) }
        if line.contains("(Y/n)") || line.contains("(y/N)") { once("q:\(line)", .question(line)) }
        if lower.contains("logged in as"), let range = line.range(of: #"(?i)logged in as\s+([A-Za-z0-9-]+)"#, options: .regularExpression) {
            let name = line[range].split(separator: " ").last.map(String.init)
            login = name
            once("logged", .succeeded(login: name))
        }
        if lower.contains("authentication complete") { completed = true }
        let withoutURLs = lower.replacingOccurrences(of: #"https?://\S+"#, with: "", options: .regularExpression)
        if !partial, !completed, withoutURLs.contains("error") || withoutURLs.contains("failed") || withoutURLs.contains("expired") {
            once("failed:\(line)", .failed(line))
        }
        return events
    }

    /// The login reported once the process ends successfully.
    public var loggedInAs: String? { login }
}

public enum GitHubLoginPhase: Equatable, Sendable {
    case starting
    /// Show the code; the user presses "Abrir navegador" (sends Enter).
    case showingCode(String)
    case waitingForBrowser(String)
    case connected(String?)
    case failed(String)

    public var isFinished: Bool {
        switch self {
        case .connected, .failed: true
        default: false
        }
    }
}

public struct GitHubLoginStateMachine: Equatable, Sendable {
    public private(set) var phase: GitHubLoginPhase = .starting
    public private(set) var code: String?

    public init() {}

    public mutating func handle(_ event: GitHubLoginEvent) {
        guard !phase.isFinished else { return }
        switch event {
        case let .oneTimeCode(code):
            self.code = code
            phase = .showingCode(code)
        case .pressEnterToOpenBrowser, .question:
            break
        case let .succeeded(login):
            phase = .connected(login)
        case let .failed(message):
            phase = .failed(message)
        }
    }

    public mutating func browserOpened() {
        if case let .showingCode(code) = phase { phase = .waitingForBrowser(code) }
    }

    public mutating func processExited(status: Int32, login: String?) {
        guard !phase.isFinished else { return }
        phase = status == 0 ? .connected(login) : .failed("processo encerrado (código \(status))")
    }

    public mutating func cancelled() {
        guard !phase.isFinished else { return }
        phase = .failed("cancelado")
    }
}

/// Test-mode stand-in for `gh auth login --web`.
public enum GitHubLoginSimulator {
    public static let executable = "/bin/sh"
    public static let simulatedLogin = "usuario-teste"
    public static var arguments: [String] { ["-c", script] }

    static let script = #"""
    printf '[MODO DE TESTE: simulação do gh auth login]\n'
    printf '! First copy your one-time code: TEST-1234\n'
    printf 'Press Enter to open https://github.com/login/device in your browser... '
    IFS= read -r answer
    sleep 1
    printf '\342\234\223 Authentication complete.\n'
    printf '\342\234\223 Logged in as usuario-teste\n'
    """#
}

extension GitHubCLI {
    /// Arguments for a browser login that adds (and activates) an account.
    public static func loginArguments(host: String) -> [String] {
        ["auth", "login", "--hostname", host, "--git-protocol", "https", "--web"]
    }
}
