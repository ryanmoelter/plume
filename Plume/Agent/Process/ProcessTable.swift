import Darwin
import Foundation

nonisolated struct ProcessTableEntry: Equatable, Sendable {
    let pid: pid_t
    let parentPID: pid_t
    let groupID: pid_t
    let command: String
}

/// Every process on the system, as `ps` reports it.
nonisolated enum ProcessTable {
    static func snapshot() -> [ProcessTableEntry] {
        guard let output = ChildProcess.capturedOutput(
            executable: "/bin/ps",
            arguments: ["-Ao", "pid=,ppid=,pgid=,command="],
            timeout: 5
        ) else { return [] }
        return parse(output)
    }

    static func parse(_ output: String) -> [ProcessTableEntry] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard fields.count == 4,
                  let pid = pid_t(fields[0]),
                  let parentPID = pid_t(fields[1]),
                  let groupID = pid_t(fields[2])
            else { return nil }
            return ProcessTableEntry(pid: pid, parentPID: parentPID, groupID: groupID, command: String(fields[3]))
        }
    }

    /// Microseconds since the epoch, or nil once the process is gone.
    static func startTime(of pid: pid_t) -> Int64? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return Int64(start.tv_sec) * 1_000_000 + Int64(start.tv_usec)
    }
}
