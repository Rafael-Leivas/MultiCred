import Foundation

/// Runs commands with `Foundation.Process`.
///
/// Both pipes are drained concurrently so a chatty child cannot deadlock on a full
/// pipe buffer. On timeout the child gets SIGTERM, then SIGKILL two seconds later,
/// and the call returns immediately: a grandchild that inherited the pipe must not
/// be able to keep us waiting.
public final class ProcessRunner: CommandRunner {
    public init() {}

    public func run(_ request: CommandRequest) async throws -> CommandResult {
        let process = Process()
        process.executableURL = request.executable
        process.arguments = request.arguments
        process.environment = request.environment
        if let directory = request.currentDirectory {
            process.currentDirectoryURL = directory
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        let stdinPipe = request.standardInput.map { _ in Pipe() }
        process.standardInput = stdinPipe ?? FileHandle.nullDevice

        let name = request.executable.lastPathComponent
        let state = RunState()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                state.setContinuation(continuation)

                let readers = DispatchGroup()
                let output = OutputBuffers()
                // Entered before launch so a fast exit cannot notify before the
                // readers exist; left by the readers once they start.
                readers.enter()
                readers.enter()

                process.terminationHandler = { finished in
                    let code = finished.terminationStatus
                    readers.notify(queue: .global()) {
                        let (out, err) = output.values
                        state.finish(.success(CommandResult(exitCode: code, standardOutput: out, standardError: err)))
                    }
                }

                do {
                    try process.run()
                } catch {
                    // Readers were never started: nothing would ever close the pipes.
                    state.finish(.failure(CommandError.launchFailed(executable: name, reason: error.localizedDescription)))
                    return
                }

                DispatchQueue.global().async {
                    output.setStdout(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
                    readers.leave()
                }
                DispatchQueue.global().async {
                    output.setStderr(stderrPipe.fileHandleForReading.readDataToEndOfFile())
                    readers.leave()
                }

                if let stdinPipe, let input = request.standardInput {
                    let handle = stdinPipe.fileHandleForWriting
                    // A child that exits without reading stdin must produce EPIPE,
                    // not a SIGPIPE that terminates the app.
                    _ = fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1)
                    DispatchQueue.global().async {
                        try? handle.write(contentsOf: input)
                        try? handle.close()
                    }
                }

                let seconds = request.timeout.timeInterval
                DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                    guard process.isRunning else { return }
                    state.finish(.failure(CommandError.timedOut(executable: name, seconds: seconds)))
                    Self.stop(process)
                }
            }
        } onCancel: {
            state.finish(.failure(CancellationError()))
            Self.stop(process)
        }
    }

    private static func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }
}

/// Resumes the continuation exactly once, whichever of exit, timeout or
/// cancellation happens first.
private final class RunState: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<CommandResult, any Error>?
    private var pending: Result<CommandResult, any Error>?
    private var done = false

    func setContinuation(_ continuation: CheckedContinuation<CommandResult, any Error>) {
        lock.lock()
        if let pending {
            lock.unlock()
            continuation.resume(with: pending)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func finish(_ result: Result<CommandResult, any Error>) {
        lock.lock()
        guard !done else { lock.unlock(); return }
        done = true
        guard let continuation else {
            pending = result
            lock.unlock()
            return
        }
        self.continuation = nil
        lock.unlock()
        continuation.resume(with: result)
    }
}

private final class OutputBuffers: @unchecked Sendable {
    private let lock = NSLock()
    private var stdout = Data()
    private var stderr = Data()

    func setStdout(_ data: Data) { lock.lock(); stdout = data; lock.unlock() }
    func setStderr(_ data: Data) { lock.lock(); stderr = data; lock.unlock() }
    var values: (Data, Data) { lock.lock(); defer { lock.unlock() }; return (stdout, stderr) }
}
