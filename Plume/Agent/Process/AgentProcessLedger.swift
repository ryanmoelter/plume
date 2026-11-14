import Foundation
import os
import Synchronization

/// The agent processes this install has running, kept on disk so a launch
/// after a crash can find the ones that outlived it.
///
/// For CLIs whose command line carries nothing of Plume's own — `codex
/// app-server` — where `ClaudeProcessScanner`'s settings-path match has
/// nothing to match. Each entry pairs the pid with its start time, so a pid
/// the system has since reused never reads as one of ours.
nonisolated struct AgentProcessLedger: Sendable {
    struct Entry: Codable, Equatable, Sendable {
        let pid: pid_t
        let startTime: Int64
    }

    let file: URL

    /// Nil in the test host, which shares the installed app's directory.
    @MainActor static var forThisInstall: AgentProcessLedger? {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return nil }
        return AgentProcessLedger(file: AppPaths.applicationSupport.appending(path: "agent-processes.json"))
    }

    /// Every ledger in the process shares one lock: they may name one file.
    private static let lock = Mutex(())

    func record(_ pid: pid_t) {
        guard let startTime = ProcessTable.startTime(of: pid) else { return }
        update { $0.append(Entry(pid: pid, startTime: startTime)) }
    }

    func remove(_ pid: pid_t) {
        update { $0.removeAll { $0.pid == pid } }
    }

    /// Recorded processes still running, dropping the rest from the file.
    func liveEntries() -> [Entry] {
        var live: [Entry] = []
        update { entries in
            entries.removeAll { ProcessTable.startTime(of: $0.pid) != $0.startTime }
            live = entries
        }
        return live
    }

    private func update(_ change: (inout [Entry]) -> Void) {
        Self.lock.withLock { _ in
            var entries = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
            change(&entries)
            do {
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(entries).write(to: file, options: .atomic)
            } catch {
                Log.agent.error("Could not write the agent process ledger: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
