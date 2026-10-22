import AppKit
import Darwin

/// Whether Orca could still be driving the agents an import would resume.
///
/// Quitting Orca leaves its terminal daemon running, and the agents in its
/// terminals with it. The daemon itself outlives Orca's Kill all sessions, so
/// only a daemon that still has child processes — one `login` per terminal —
/// counts.
nonisolated enum OrcaRunningState {
    static let bundleIdentifier = "com.stablyai.orca"

    static func isRunning() -> Bool {
        isRunning(
            appIsRunning: !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty,
            daemonDirectory: OrcaLocations.daemonDirectory,
            hasTerminals: hasChildProcesses
        )
    }

    static func isRunning(appIsRunning: Bool, daemonDirectory: URL, hasTerminals: (pid_t) -> Bool) -> Bool {
        appIsRunning || daemonPIDs(in: daemonDirectory).contains(where: hasTerminals)
    }

    /// The pids recorded in `daemon-v*.pid`, which Orca writes as JSON with a
    /// `pid` field. Old protocol versions leave their files behind, so a pid
    /// here may be long dead or reused.
    static func daemonPIDs(in directory: URL) -> [pid_t] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.lastPathComponent.hasPrefix("daemon-v") && $0.pathExtension == "pid" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url),
                      let record = try? JSONDecoder().decode(PIDRecord.self, from: data),
                      let pid = record.pid, pid > 0, pid <= Double(Int32.max)
                else { return nil }
                return pid_t(pid)
            }
    }

    /// False for a dead pid, which has no children. A reused pid that happens
    /// to have children reads as true, which only shows a needless warning.
    static func hasChildProcesses(_ pid: pid_t) -> Bool {
        var children = [pid_t](repeating: 0, count: 64)
        let count = children.withUnsafeMutableBytes { buffer in
            proc_listchildpids(pid, buffer.baseAddress, Int32(buffer.count))
        }
        return count > 0
    }

    private struct PIDRecord: Decodable {
        let pid: Double?
    }
}
