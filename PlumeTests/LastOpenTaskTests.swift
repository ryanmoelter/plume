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

    @Test func aSavedIDLoadsBack() {
        let store = defaults()
        let id = UUID()
        LastOpenTask.save(id, to: store)
        #expect(LastOpenTask.load(from: store) == id)
    }

    @Test func savingNilClearsTheStoredID() {
        let store = defaults()
        LastOpenTask.save(UUID(), to: store)
        LastOpenTask.save(nil, to: store)
        #expect(LastOpenTask.load(from: store) == nil)
    }

    @Test func aValueThatIsNotAUUIDLoadsAsNil() {
        let store = defaults()
        store.set("not-a-uuid", forKey: "lastOpenTaskID")
        #expect(LastOpenTask.load(from: store) == nil)
    }
}
