import Foundation
import Observation

/// The command-mode commands still running, per tab.
///
/// Held here rather than by the composer, so a run survives the composer
/// unmounting on a tab or task switch and stays visible and cancellable when
/// the user comes back.
@MainActor
@Observable
final class CommandModeRuns {
    static let shared = CommandModeRuns()

    struct Run: Identifiable {
        let id = UUID()
        let command: String
        /// The newest line the command has printed, for a live preview while
        /// it works. Empty until it prints anything.
        var latestOutput = ""
        /// Set once the command has exited and its output is waiting on a
        /// turn to end. The chip stays up meanwhile: the text it carries is
        /// the tagged wire format, which reads as markup rather than as the
        /// command the user ran.
        var isQueued = false
        /// The text handed to the agent, so the queued list can tell which
        /// of its entries this chip already speaks for.
        fileprivate(set) var queuedText: String?
        fileprivate var task: Task<Void, Never>?
    }

    private var runsByTab: [UUID: [Run]] = [:]

    init() {}

    func runs(forTab id: UUID) -> [Run] {
        runsByTab[id] ?? []
    }

    /// `onFinish` gets the run's id and the result unless the run was
    /// cancelled, in which case the command's output goes nowhere. It runs
    /// while the chip is still listed, so a caller handing the result to a
    /// busy session can leave the chip up until the turn takes it.
    ///
    /// The id rides on the closure, not only the return value: a closure that
    /// names the `let` it initializes compiles without a diagnostic and
    /// captures uninitialized memory.
    @discardableResult
    func start(
        _ command: String,
        in directory: String?,
        tabID: UUID,
        onFinish: @escaping (Run.ID, CommandModeResult) -> Void
    ) -> Run.ID {
        var run = Run(command: command)
        let runID = run.id
        run.task = Task {
            let result = await CommandModeRunner.run(command, in: directory) { line in
                Task { @MainActor in self.setLatestOutput(line, runID: runID, tabID: tabID) }
            }
            guard result.ending != .cancelled else {
                remove(runID, tabID: tabID)
                return
            }
            setQueued(runID, tabID: tabID, text: result.transcriptText)
            onFinish(runID, result)
        }
        runsByTab[tabID, default: []].append(run)
        return runID
    }

    /// Drops the chip once its text has actually reached the agent.
    func finish(_ runID: UUID, tabID: UUID) {
        remove(runID, tabID: tabID)
    }

    /// The wire text of every run whose output is still waiting on a turn,
    /// so the queued list can leave those to their own chips.
    func queuedText(forTab id: UUID) -> Set<String> {
        Set(runs(forTab: id).compactMap(\.queuedText))
    }

    private func setQueued(_ runID: UUID, tabID: UUID, text: String) {
        guard let index = runsByTab[tabID]?.firstIndex(where: { $0.id == runID }) else { return }
        runsByTab[tabID]?[index].isQueued = true
        runsByTab[tabID]?[index].queuedText = text
    }

    private func setLatestOutput(_ line: String, runID: UUID, tabID: UUID) {
        guard let index = runsByTab[tabID]?.firstIndex(where: { $0.id == runID }) else { return }
        runsByTab[tabID]?[index].latestOutput = line
    }

    func cancel(_ runID: UUID, tabID: UUID, session: (any AgentSession)? = nil) {
        let run = runs(forTab: tabID).first { $0.id == runID }
        if let text = run?.queuedText, let session,
           let index = session.queuedMessages.firstIndex(where: { $0.plainText == text }) {
            session.removeQueuedMessage(at: index)
        }
        run?.task?.cancel()
        remove(runID, tabID: tabID)
    }

    func forget(tabID: UUID) {
        runs(forTab: tabID).forEach { $0.task?.cancel() }
        runsByTab.removeValue(forKey: tabID)
    }

    private func remove(_ runID: UUID, tabID: UUID) {
        runsByTab[tabID]?.removeAll { $0.id == runID }
        if runsByTab[tabID]?.isEmpty == true { runsByTab.removeValue(forKey: tabID) }
    }
}
