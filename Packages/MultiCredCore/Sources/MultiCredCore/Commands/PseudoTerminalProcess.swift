import Foundation

/// Runs one process attached to a pseudo-terminal, for `claude auth login`,
/// which needs a TTY for its prompt.
///
/// Chosen over SwiftTerm (D29): SwiftTerm 1.20 requires the Metal toolchain and a
/// build plugin, and 1.2.x does not expose the child process, so it could not
/// be terminated when the login window closes.
///
/// The master side is read with `read(2)` on a dispatch source: once the child
/// exits, macOS answers EIO, which `FileHandle.availableData` would turn into an
/// Objective-C exception (a crash). `onExit` fires once, after the output was
/// drained or one second after the process ended, whichever comes first.
public final class PseudoTerminalProcess: @unchecked Sendable {
    public enum PTYError: Error, Equatable {
        case openFailed(String)
        case launchFailed(String)
        case alreadyStarted
    }

    private let lock = NSLock()
    private var process: Process?
    private var masterFD: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var exitStatus: Int32?
    private var outputClosed = false
    private var exitReported = false
    private var onExit: (@Sendable (Int32) -> Void)?
    private let queue = DispatchQueue(label: "app.multicred.pty")

    public init() {}

    public var isRunning: Bool {
        lock.withLock { process?.isRunning ?? false }
    }

    public var processIdentifier: Int32? {
        lock.withLock { process?.processIdentifier }
    }

    public func start(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        currentDirectory: URL? = nil,
        columns: UInt16 = 100,
        rows: UInt16 = 24,
        onOutput: @escaping @Sendable (Data) -> Void,
        onExit: @escaping @Sendable (Int32) -> Void
    ) throws {
        try lock.withLock {
            guard process == nil else { throw PTYError.alreadyStarted }
        }

        let master = posix_openpt(O_RDWR | O_NOCTTY)
        guard master >= 0 else { throw PTYError.openFailed(String(cString: strerror(errno))) }
        guard grantpt(master) == 0, unlockpt(master) == 0, let name = ptsname(master) else {
            let reason = String(cString: strerror(errno))
            close(master)
            throw PTYError.openFailed(reason)
        }
        let slave = open(name, O_RDWR | O_NOCTTY)
        guard slave >= 0 else {
            let reason = String(cString: strerror(errno))
            close(master)
            throw PTYError.openFailed(reason)
        }
        var size = winsize(ws_row: rows, ws_col: columns, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(master, TIOCSWINSZ, &size)
        _ = fcntl(master, F_SETFD, FD_CLOEXEC)
        _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK)

        let slaveHandle = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
        let child = Process()
        child.executableURL = executable
        child.arguments = arguments
        child.environment = environment
        if let currentDirectory { child.currentDirectoryURL = currentDirectory }
        child.standardInput = slaveHandle
        child.standardOutput = slaveHandle
        child.standardError = slaveHandle
        child.terminationHandler = { [weak self] finished in
            self?.processEnded(status: finished.terminationStatus)
        }

        lock.withLock {
            self.masterFD = master
            self.onExit = onExit
            self.process = child
        }

        do {
            try child.run()
        } catch {
            close(slave)
            close(master)
            lock.withLock {
                self.process = nil
                self.masterFD = -1
                self.onExit = nil
            }
            throw PTYError.launchFailed(error.localizedDescription)
        }
        // The child has its own copy; ours would keep the output from ever ending.
        close(slave)

        let source = DispatchSource.makeReadSource(fileDescriptor: master, queue: queue)
        source.setEventHandler { [weak self] in
            var buffer = [UInt8](repeating: 0, count: 8192)
            while true {
                let count = read(master, &buffer, buffer.count)
                if count > 0 {
                    onOutput(Data(buffer[0..<count]))
                    continue
                }
                if count < 0, errno == EINTR { continue }
                if count < 0, errno == EAGAIN { return }
                // 0 bytes or EIO: the terminal closed.
                self?.outputEnded()
                return
            }
        }
        source.setCancelHandler {
            close(master)
        }
        lock.withLock { readSource = source }
        source.resume()
    }

    /// Writes to the process's terminal input, as if typed.
    /// Types a code into an interactive CLI and presses Enter. The two are sent
    /// apart: Claude Code (Ink) treats a long text arriving in one read as a
    /// paste and swallows a trailing Enter in it (seen with setup-token 2.1.301:
    /// a ~90-character code + "\r" in one write never submits).
    public func submitLine(_ text: String, enterDelay: Duration = .milliseconds(300)) {
        write(Data(text.utf8))
        let delay = Double(enterDelay.components.seconds) + Double(enterDelay.components.attoseconds) / 1e18
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [self] in
            write(Data("\r".utf8))
        }
    }

    public func write(_ data: Data) {
        let fd = lock.withLock { masterFD }
        guard fd >= 0 else { return }
        data.withUnsafeBytes { buffer in
            var offset = 0
            var attempts = 0
            while offset < buffer.count, attempts < 1000 {
                let written = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if written > 0 {
                    offset += written
                } else if errno == EAGAIN || errno == EINTR {
                    attempts += 1
                    usleep(1000)
                } else {
                    return
                }
            }
        }
    }

    /// SIGTERM, then SIGKILL two seconds later if it is still running.
    public func terminate() {
        guard let child = lock.withLock({ process }), child.isRunning else { return }
        child.terminate()
        let pid = child.processIdentifier
        queue.asyncAfter(deadline: .now() + 2) {
            if child.isRunning { kill(pid, SIGKILL) }
        }
    }

    private func outputEnded() {
        let source = lock.withLock { () -> DispatchSourceRead? in
            outputClosed = true
            defer { readSource = nil }
            return readSource
        }
        source?.cancel()
        reportExitIfReady(force: false)
    }

    private func processEnded(status: Int32) {
        lock.withLock { exitStatus = status }
        reportExitIfReady(force: false)
        // A grandchild may keep the terminal open; do not wait for it forever.
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.reportExitIfReady(force: true)
        }
    }

    private func reportExitIfReady(force: Bool) {
        let callback: (@Sendable (Int32) -> Void, Int32)? = lock.withLock {
            guard !exitReported, let status = exitStatus, outputClosed || force, let onExit else { return nil }
            exitReported = true
            return (onExit, status)
        }
        guard let (handler, status) = callback else { return }
        if force { lock.withLock { readSource }?.cancel() }
        handler(status)
    }
}
