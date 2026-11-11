import Darwin
import Foundation
import Observation
import os

/// Ends the agents a previous run of this install left behind, before any tab
/// resumes their sessions.
///
/// A crash leaves each agent running under launchd, still writing its
/// transcript, and `OrphanedSessionDetector` then refuses to resume a session
/// on top of it. Reaping first lets the tab come back through `--resume`; a
/// turn the crash interrupted is lost.
///
/// Only orphans this install spawned are touched: a `claude` carrying this
/// install's settings path, or a pid in this install's `AgentProcessLedger`.
/// Both live under the per-install support directory, so a Debug build never
/// reaps the installed app's agents.
@MainActor
@Observable
final class OrphanedAgentReaper {
    static let shared = OrphanedAgentReaper()

    /// Resuming waits on this.
    private(set) var hasFinished = false
    @ObservationIgnored private var didStart = false

    func start() {
        guard !didStart else { return }
        didStart = true
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else {
            hasFinished = true
            return
        }
        let settingsPath = AppPaths.hookSettingsFile.path
        let ledger = AgentProcessLedger.forThisInstall
        Task.detached(priority: .userInitiated) {
            Self.reap(settingsPath: settingsPath, ledger: ledger)
            await MainActor.run { OrphanedAgentReaper.shared.hasFinished = true }
        }
    }

    nonisolated private static func reap(settingsPath: String, ledger: AgentProcessLedger?) {
        let ledgerPIDs = Set(ledger?.liveEntries().map(\.pid) ?? [])
        let targets = OrphanedAgentSelection.targets(
            in: ProcessTable.snapshot(),
            settingsPath: settingsPath,
            ledgerPIDs: ledgerPIDs,
            ownGroupID: getpgrp()
        )
        guard !targets.isEmpty else { return }
        Log.agent.notice("Reaping \(targets.count, privacy: .public) orphaned agent(s): \(targets.map(\.description).joined(separator: ", "), privacy: .public)")

        for target in targets { target.send(SIGTERM) }
        if !waitUntilGone(targets, within: 2) {
            for target in targets where target.isAlive { target.send(SIGKILL) }
            _ = waitUntilGone(targets, within: 1)
        }
        for target in targets { ledger?.remove(target.pid) }
    }

    nonisolated private static func waitUntilGone(_ targets: [OrphanedAgentSelection.Target], within timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !targets.contains(where: \.isAlive) { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return !targets.contains(where: \.isAlive)
    }
}

/// Which processes in a snapshot are this install's orphaned agents.
nonisolated enum OrphanedAgentSelection {
    struct Target: Equatable, Sendable, CustomStringConvertible {
        let pid: pid_t
        /// Set when the agent leads a process group that it or its spawning
        /// shell created, so a signal also ends the agent's own children.
        let groupID: pid_t?

        func send(_ signal: Int32) {
            if let groupID { kill(-groupID, signal) } else { kill(pid, signal) }
        }

        var isAlive: Bool {
            let id = groupID.map { -$0 } ?? pid
            return kill(id, 0) == 0 || errno == EPERM
        }

        var description: String { groupID.map { "group \($0)" } ?? "pid \(pid)" }
    }

    static func targets(
        in table: [ProcessTableEntry],
        settingsPath: String,
        ledgerPIDs: Set<pid_t>,
        ownGroupID: pid_t
    ) -> [Target] {
        let byPID = Dictionary(table.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        var targets: [Target] = []
        var seenGroups: Set<pid_t> = []
        for entry in table {
            let isOurs = ledgerPIDs.contains(entry.pid)
                || ClaudeProcessScanner.isPlumeAgent(command: entry.command[...], settingsPath: settingsPath)
            guard isOurs, entry.pid > 1, isOrphaned(entry, byPID: byPID) else { continue }

            if leadsOwnGroup(entry, byPID: byPID), entry.groupID != ownGroupID {
                guard seenGroups.insert(entry.groupID).inserted else { continue }
                targets.append(Target(pid: entry.pid, groupID: entry.groupID))
            } else {
                targets.append(Target(pid: entry.pid, groupID: nil))
            }
        }
        return targets
    }

    /// Walks up through the agent's own process group — the `sh -m` that
    /// launched it, when the shell did not exec away — and reports whether
    /// the first ancestor outside it is launchd. A live app is that ancestor
    /// for every agent it still owns.
    static func isOrphaned(_ entry: ProcessTableEntry, byPID: [pid_t: ProcessTableEntry]) -> Bool {
        var current = entry
        var visited: Set<pid_t> = [entry.pid]
        while true {
            if current.parentPID == 1 { return true }
            guard let parent = byPID[current.parentPID], parent.groupID == entry.groupID,
                  visited.insert(parent.pid).inserted
            else { return false }
            current = parent
        }
    }

    /// The group is the agent's own only when its leader is the agent or one
    /// of the agent's ancestors. Otherwise signalling the group could reach
    /// processes that merely share it.
    static func leadsOwnGroup(_ entry: ProcessTableEntry, byPID: [pid_t: ProcessTableEntry]) -> Bool {
        guard entry.groupID > 1 else { return false }
        var current = entry
        var visited: Set<pid_t> = []
        while visited.insert(current.pid).inserted {
            if current.pid == entry.groupID { return true }
            guard let parent = byPID[current.parentPID], parent.groupID == entry.groupID else { return false }
            current = parent
        }
        return false
    }
}
