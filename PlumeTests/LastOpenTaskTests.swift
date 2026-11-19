import Foundation
import Testing
@testable import Plume

/// The last selected task is known at once, written to user defaults only once
/// selection settles, and only when it changed. Home and a cleared selection
/// leave it in place.
@MainActor
struct LastOpenTaskTests {
    private let store = UserDefaults(suiteName: UUID().uuidString)!
    private let key = "lastSelectedTaskID"

    private func recorder(writeDelay: Duration = .seconds(60)) -> LastOpenTask {
        LastOpenTask(defaults: store, writeDelay: writeDelay)
    }

    @Test func anUnsetTaskLoadsAsNil() {
        #expect(recorder().lastTask == nil)
    }

    @Test func aStoredTaskLoadsBack() {
        let id = UUID()
        store.set(id.uuidString, forKey: key)
        #expect(recorder().lastTask == id)
    }

    @Test func aValueThatIsNotAUUIDLoadsAsNil() {
        store.set("not-a-uuid", forKey: key)
        #expect(recorder().lastTask == nil)
    }

    @Test func aRecordedTaskIsReadableBeforeItIsWritten() {
        let recorder = recorder()
        let id = UUID()
        recorder.record(.task(id))
        #expect(recorder.lastTask == id)
        #expect(store.string(forKey: key) == nil)
    }

    @Test func flushWritesOnlyTheLastOfSeveralSelections() {
        let recorder = recorder()
        let last = UUID()
        recorder.record(.task(UUID()))
        recorder.record(.task(UUID()))
        recorder.record(.task(last))
        recorder.flush()
        #expect(store.string(forKey: key) == last.uuidString)
    }

    @Test func homeAndNilLeaveTheLastTaskInPlace() {
        let recorder = recorder()
        let id = UUID()
        recorder.record(.task(id))
        recorder.record(.home)
        recorder.record(nil)
        recorder.flush()
        #expect(recorder.lastTask == id)
        #expect(store.string(forKey: key) == id.uuidString)
    }

    @Test func reselectingTheWrittenTaskWritesNothing() {
        let id = UUID()
        store.set(id.uuidString, forKey: key)
        let recorder = recorder()
        store.set("sentinel", forKey: key)
        recorder.record(.task(id))
        recorder.flush()
        #expect(store.string(forKey: key) == "sentinel")
    }

    @Test func theWriteLandsOnItsOwnOnceSelectionSettles() async throws {
        let recorder = recorder(writeDelay: .milliseconds(10))
        let id = UUID()
        recorder.record(.task(id))
        for _ in 0..<200 where store.string(forKey: key) == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.string(forKey: key) == id.uuidString)
    }
}
