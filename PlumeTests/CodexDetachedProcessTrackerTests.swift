import Foundation
import Testing
@testable import Plume

@MainActor
struct CodexDetachedProcessTrackerTests {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func process(_ id: String = "kernel-1", startedAt: Date? = nil) -> CodexDetachedProcess {
        CodexDetachedProcess(id: id, startedAt: startedAt ?? start)
    }

    private func entry(_ id: String) -> BackgroundTaskTracker.Entry {
        BackgroundTaskTracker.Entry(id: id, kind: .monitor, startedAt: Date(), expiresAt: nil)
    }

    @Test func confirmedProcessesOutlastTheInferredHardCap() {
        let background = BackgroundTaskTracker()
        let detached = CodexDetachedProcessTracker(backgroundTasks: background)
        let tab = UUID()
        let generation = detached.begin(tabID: tab)
        detached.replace(tabID: tab, generation: generation, processes: [process()])
        #expect(background.inFlight(tabID: tab, now: start.addingTimeInterval(7 * 24 * 60 * 60)).count == 1)
        #expect(background.tabsWithBackgroundTasks.map(\.count) == [1])
        detached.replace(tabID: tab, generation: generation, processes: [])
        #expect(background.inFlight(tabID: tab).isEmpty)
    }

    @Test func detachedMembershipIsAdditiveToLiveAndInferredInventories() {
        let background = BackgroundTaskTracker()
        let detached = CodexDetachedProcessTracker(backgroundTasks: background)
        let tab = UUID()
        background.replace(tabID: tab, entries: [entry("managed")])
        let generation = detached.begin(tabID: tab)
        detached.replace(tabID: tab, generation: generation, processes: [process()])
        #expect(Set(background.inFlight(tabID: tab).map(\.id)) == ["managed", "codex-detached/kernel-1"])
        background.replaceLive(tabID: tab, entries: [])
        #expect(background.inFlight(tabID: tab).map(\.id) == ["codex-detached/kernel-1"])
        background.replaceLive(tabID: tab, entries: [entry("live")])
        detached.end(tabID: tab, generation: generation)
        #expect(background.inFlight(tabID: tab).map(\.id) == ["live"])
    }

    @Test func duplicateKernelIdentitiesCountOnceAcrossSnapshots() {
        let background = BackgroundTaskTracker()
        let detached = CodexDetachedProcessTracker(backgroundTasks: background)
        let tab = UUID()
        let generation = detached.begin(tabID: tab)
        detached.replace(tabID: tab, generation: generation, processes: [
            process(), process(startedAt: start.addingTimeInterval(10))
        ])
        detached.replace(tabID: tab, generation: generation, processes: [process(startedAt: start.addingTimeInterval(30))])
        let running = background.inFlight(tabID: tab)
        #expect(running.count == 1)
        #expect(running.first?.startedAt == start)
        #expect(running.first?.description == "Detached command")
    }

    @Test func anOldGenerationCannotReplaceOrEndItsSuccessor() {
        let background = BackgroundTaskTracker()
        let detached = CodexDetachedProcessTracker(backgroundTasks: background)
        let tab = UUID()
        let old = detached.begin(tabID: tab)
        let current = detached.begin(tabID: tab)
        detached.replace(tabID: tab, generation: current, processes: [process("new")])
        detached.replace(tabID: tab, generation: old, processes: [process("old")])
        detached.end(tabID: tab, generation: old)
        #expect(background.inFlight(tabID: tab).map(\.id) == ["codex-detached/new"])
    }

    @Test func tabCloseAndResetRejectLateCallbacks() {
        let background = BackgroundTaskTracker()
        let detached = CodexDetachedProcessTracker(backgroundTasks: background)
        let tab = UUID(), other = UUID()
        let generation = detached.begin(tabID: tab), second = detached.begin(tabID: other)
        detached.replace(tabID: tab, generation: generation, processes: [process()])
        detached.replace(tabID: other, generation: second, processes: [process("other")])
        background.forget(tabID: tab)
        detached.replace(tabID: tab, generation: generation, processes: [process()])
        #expect(background.inFlight(tabID: tab).isEmpty)
        #expect(background.inFlight(tabID: other).count == 1)
        background.reset()
        detached.replace(tabID: other, generation: second, processes: [process("other")])
        #expect(background.tabsWithBackgroundTasks.isEmpty)
    }

    @Test func nativeInventoryShutdownDoesNotClearDetachedOrLiveMembership() {
        let background = BackgroundTaskTracker()
        let detached = CodexDetachedProcessTracker(backgroundTasks: background)
        let tab = UUID()
        let generation = detached.begin(tabID: tab)
        detached.replace(tabID: tab, generation: generation, processes: [process()])
        background.replace(tabID: tab, entries: [entry("managed")])
        background.replaceLive(tabID: tab, entries: [entry("live")])
        let native = CodexBackgroundTaskTracker(tabID: tab, tracker: background) { _, _ in .object([:]) }
        native.stop()
        #expect(Set(background.inFlight(tabID: tab).map(\.id)) == ["live", "codex-detached/kernel-1"])
        detached.end(tabID: tab, generation: generation)
        detached.replace(tabID: tab, generation: generation, processes: [process()])
        #expect(background.inFlight(tabID: tab).map(\.id) == ["live"])
    }
}
