import Darwin
import Foundation

/// Counts running processes by name for the current user, without reading
/// their memory or environment (that is restricted on macOS and not needed:
/// the HUD only says "N Claude Code sessions keep their previous account").
public protocol ProcessScanning: Sendable {
    func countProcesses(named name: String) -> Int
}

public struct SystemProcessScanner: ProcessScanning {
    public init() {}

    public func countProcesses(named name: String) -> Int {
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return 0 }
        var pids = [pid_t](repeating: 0, count: Int(capacity) + 32)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard filled > 0 else { return 0 }
        let me = getpid()
        let uid = getuid()
        var count = 0
        for pid in pids.prefix(Int(filled)) where pid > 0 && pid != me {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_uid == uid else { continue }
            var buffer = [CChar](repeating: 0, count: 256)
            guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { continue }
            if String(cString: buffer) == name { count += 1 }
        }
        return count
    }
}

public struct FixedProcessScanner: ProcessScanning {
    public let counts: [String: Int]
    public init(_ counts: [String: Int]) { self.counts = counts }
    public func countProcesses(named name: String) -> Int { counts[name] ?? 0 }
}
