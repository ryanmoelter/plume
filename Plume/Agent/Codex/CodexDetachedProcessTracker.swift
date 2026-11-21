import Foundation

nonisolated struct CodexDetachedProcess: Equatable, Sendable {
    let id: String
    let startedAt: Date
}

@MainActor
final class CodexDetachedProcessTracker {
    static let shared = CodexDetachedProcessTracker()

    private let backgroundTasks: BackgroundTaskTracker

    init(backgroundTasks: BackgroundTaskTracker = .shared) {
        self.backgroundTasks = backgroundTasks
    }

    func begin(tabID: UUID) -> UUID {
        backgroundTasks.beginDetached(tabID: tabID)
    }

    func replace(tabID: UUID, generation: UUID, processes: [CodexDetachedProcess]) {
        backgroundTasks.replaceDetached(tabID: tabID, generation: generation, entries: processes.map {
            BackgroundTaskTracker.Entry(
                id: "codex-detached/\($0.id)", kind: .backgroundCommand,
                description: "Detached command", startedAt: $0.startedAt, expiresAt: nil
            )
        })
    }

    func end(tabID: UUID, generation: UUID) {
        backgroundTasks.endDetached(tabID: tabID, generation: generation)
    }
}
