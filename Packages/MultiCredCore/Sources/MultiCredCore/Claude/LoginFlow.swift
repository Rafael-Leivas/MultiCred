import Foundation

/// Things `claude auth login` says, recognized from its terminal output.
/// Patterns come from a real transcript (docs/spikes/claude-config-dir.md, item d):
///
/// ```
/// Opening browser to sign in…
/// If the browser didn't open, visit: <OSC 8 link>https://claude.com/cai/oauth/authorize?…
/// Paste code here if prompted > Login successful.
/// ```
public enum LoginEvent: Equatable, Sendable {
    case openingBrowser
    case authorizationURL(URL)
    case promptingForCode
    case succeeded
    case failed(String)
}

/// Turns raw PTY bytes into `LoginEvent`s. Escape sequences (colors, OSC 8
/// hyperlinks, cursor moves) are removed first. Each event fires once.
public struct LoginOutputParser: Sendable {
    private var pending = ""
    private var emitted = Set<String>()
    /// Visible text so far, without escape sequences ("Copy log").
    public private(set) var transcript = ""

    public init() {}

    public mutating func consume(_ bytes: some Sequence<UInt8>) -> [LoginEvent] {
        let text = Self.stripEscapes(String(decoding: Array(bytes), as: UTF8.self))
        transcript += text
        pending += text
        var events: [LoginEvent] = []

        // Complete lines first. `isNewline` matters: a PTY sends "\r\n", which
        // Swift treats as one Character equal to neither "\r" nor "\n".
        while let newline = pending.firstIndex(where: \.isNewline) {
            let line = String(pending[..<newline])
            pending.removeSubrange(...newline)
            events += classify(line)
        }
        // The code prompt has no newline after it.
        events += classify(pending, partial: true)
        return events
    }

    private mutating func classify(_ rawLine: String, partial: Bool = false) -> [LoginEvent] {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return [] }
        let lower = line.lowercased()
        var events: [LoginEvent] = []

        func once(_ key: String, _ event: LoginEvent) {
            if emitted.insert(key).inserted { events.append(event) }
        }

        if lower.contains("opening browser") { once("open", .openingBrowser) }
        if let range = line.range(of: #"https://[^\s<>"']+"#, options: .regularExpression),
           !partial || lower.contains("visit"),
           let url = URL(string: String(line[range])) {
            once("url", .authorizationURL(url))
        }
        if lower.contains("paste code") { once("prompt", .promptingForCode) }
        // Failure words are looked for outside URLs: an authorization URL can
        // contain "error", "invalid" or "denied" in its host or parameters.
        let withoutURLs = lower.replacingOccurrences(of: #"https?://\S+"#, with: "", options: .regularExpression)
        if lower.contains("login successful") || lower.contains("logged in as") {
            once("success", .succeeded)
        } else if !partial, ["error", "invalid", "expired", "failed", "denied"].contains(where: withoutURLs.contains) {
            once("failed:\(line)", .failed(line))
        }
        return events
    }

    /// Removes CSI (`ESC [ … letter`), OSC (`ESC ] … BEL` or `ESC ] … ESC \`)
    /// and other two-byte escapes.
    static func stripEscapes(_ text: String) -> String {
        var result = ""
        var scalars = text.unicodeScalars.makeIterator()
        while let scalar = scalars.next() {
            guard scalar == "\u{1B}" else {
                if scalar == "\u{07}" { continue }
                result.unicodeScalars.append(scalar)
                continue
            }
            guard let kind = scalars.next() else { break }
            switch kind {
            case "[":
                while let next = scalars.next(), !(0x40...0x7E).contains(next.value) {}
            case "]":
                var previous: Unicode.Scalar?
                while let next = scalars.next() {
                    if next == "\u{07}" || (previous == "\u{1B}" && next == "\\") { break }
                    previous = next
                }
            default:
                break
            }
        }
        return result
    }
}

/// Phases of the login window (design 05a/05b).
public enum LoginPhase: Equatable, Sendable {
    case starting
    case waitingForBrowser
    case waitingForCode
    case connecting
    case connected
    case failed(String)

    public var isFinished: Bool {
        switch self {
        case .connected, .failed: true
        default: false
        }
    }
}

/// Pure state machine for a login attempt; the window feeds it events.
///
/// ```
/// starting ─opening/URL─► waitingForBrowser ─prompt─► waitingForCode ─code sent─► connecting
///     │                          │                                                 │
///     │                          └── browser callback completed on its own ───────►├─ success ─► connected
///     └── failure text / exit ≠ 0 / timeout ────────────────────────────────────────┴───────────► failed
/// ```
/// `connected` and `failed` are final; a retry starts a new machine.
public struct LoginStateMachine: Equatable, Sendable {
    public private(set) var phase: LoginPhase = .starting
    public private(set) var authorizationURL: URL?

    public init() {}

    public mutating func handle(_ event: LoginEvent) {
        if case let .authorizationURL(url) = event { authorizationURL = url }
        guard !phase.isFinished else { return }
        switch event {
        case .openingBrowser, .authorizationURL:
            if phase == .starting { phase = .waitingForBrowser }
        case .promptingForCode:
            if phase == .starting || phase == .waitingForBrowser { phase = .waitingForCode }
        case .succeeded:
            phase = .connected
        case let .failed(message):
            phase = .failed(message)
        }
    }

    /// The user pasted a code and it was sent to the process.
    public mutating func codeSubmitted() {
        if phase == .waitingForCode || phase == .waitingForBrowser { phase = .connecting }
    }

    public mutating func processExited(status: Int32) {
        guard !phase.isFinished else { return }
        phase = status == 0 ? .connected : .failed("processo encerrado (código \(status))")
    }

    public mutating func timedOut() {
        guard !phase.isFinished else { return }
        phase = .failed("tempo esgotado")
    }

    public mutating func cancelled() {
        guard !phase.isFinished else { return }
        phase = .failed("cancelado")
    }
}
