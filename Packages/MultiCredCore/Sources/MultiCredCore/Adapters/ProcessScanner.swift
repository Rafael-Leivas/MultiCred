import Darwin
import Foundation

/// Counts running Claude Code sessions for the current user, without reading
/// their memory or environment (restricted on macOS, and not needed: the HUD
/// only says "N Claude Code sessions keep their previous account").
public protocol ProcessScanning: Sendable {
    func claudeCodeSessionCount() -> Int
}

/// A running process, as far as the scanner needs.
struct ProcessEntry: Equatable, Sendable {
    let pid: Int32
    let parent: Int32
    let path: String
}

public struct SystemProcessScanner: ProcessScanning {
    public init() {}

    public func claudeCodeSessionCount() -> Int {
        Self.countSessions(in: listOwnProcesses())
    }

    /// Claude Code's native install runs `~/.local/bin/claude`, which execs
    /// `~/.local/share/claude/versions/<version>` and spawns helpers
    /// (`ClaudeCode.app/.../claude`). One session = one Claude Code process
    /// whose parent is not Claude Code (a shell, an editor, launchd).
    static func countSessions(in processes: [ProcessEntry]) -> Int {
        let claudePIDs = Set(processes.filter { isClaudeCode($0.path) }.map(\.pid))
        return processes.filter { claudePIDs.contains($0.pid) && !claudePIDs.contains($0.parent) }.count
    }

    static func isClaudeCode(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        return url.lastPathComponent == "claude" || path.contains("/claude/versions/")
    }

    private func listOwnProcesses() -> [ProcessEntry] {
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(capacity) + 32)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard filled > 0 else { return [] }
        let me = getpid()
        let uid = getuid()
        return pids.prefix(Int(filled)).compactMap { pid in
            guard pid > 0, pid != me else { return nil }
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_uid == uid else { return nil }
            var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
            guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
            return ProcessEntry(pid: pid, parent: Int32(info.pbi_ppid), path: String(cString: buffer))
        }
    }
}

public struct FixedProcessScanner: ProcessScanning {
    public let sessions: Int
    public init(sessions: Int) { self.sessions = sessions }
    public func claudeCodeSessionCount() -> Int { sessions }
}
