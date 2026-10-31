import Foundation
import Testing
@testable import Plume

/// Round-trips the remembered selection, including the clearing that keeps a
/// deleted task from being restored on the next launch.
struct LastOpenTaskTests {
    private func defaults(_ name: String = UUID().uuidString) -> UserDefaults {
        UserDefaults(suiteName: name)!
    }

    @Test func anUnsetSelectionLoadsAsNil() {
        #expect(LastOpenTask.load(from: defaults()) == nil)
    }

    @Test func aSavedTaskLoadsBack() {
        let store = defaults()
        let id = UUID()
        LastOpenTask.save(.task(id), to: store)
        #expect(LastOpenTask.load(from: store) == .task(id))
    }

    @Test func homeLoadsBack() {
        let store = defaults()
        LastOpenTask.save(.home, to: store)
        #expect(LastOpenTask.load(from: store) == .home)
    }

    @Test func aTaskSavedOverHomeReplacesIt() {
        let store = defaults()
        let id = UUID()
        LastOpenTask.save(.home, to: store)
        LastOpenTask.save(.task(id), to: store)
        #expect(LastOpenTask.load(from: store) == .task(id))
    }

    @Test func savingNilClearsTheStoredID() {
        let store = defaults()
        LastOpenTask.save(.task(UUID()), to: store)
        LastOpenTask.save(nil, to: store)
        #expect(LastOpenTask.load(from: store) == nil)
    }

    @Test func aValueThatIsNotAUUIDLoadsAsNil() {
        let store = defaults()
        store.set("not-a-uuid", forKey: "lastOpenTaskID")
        #expect(LastOpenTask.load(from: store) == nil)
    }
}
