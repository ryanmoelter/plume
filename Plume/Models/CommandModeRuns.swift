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
        fileprivate var task: Task<Void, Never>?
    }

    private var runsByTab: [UUID: [Run]] = [:]

    init() {}

    func runs(forTab id: UUID) -> [Run] {
        runsByTab[id] ?? []
    }

    /// `onFinish` gets the result unless the run was cancelled, in which case
    /// the command's output goes nowhere.
    func start(
        _ command: String,
        in directory: String?,
        tabID: UUID,
        onFinish: @escaping (CommandModeResult) -> Void
    ) {
        var run = Run(command: command)
        let runID = run.id
        run.task = Task {
            let result = await CommandModeRunner.run(command, in: directory)
            remove(runID, tabID: tabID)
            if result.ending != .cancelled { onFinish(result) }
        }
        runsByTab[tabID, default: []].append(run)
    }

    func cancel(_ runID: UUID, tabID: UUID) {
        runs(forTab: tabID).first { $0.id == runID }?.task?.cancel()
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
