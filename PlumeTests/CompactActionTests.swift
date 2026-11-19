import Testing
@testable import Plume

@MainActor
struct CompactActionTests {
    @Test func availableWhenIdleWithAConversation() {
        #expect(CompactAction.availability(isWorking: false, isRestarting: false, hasConversation: true) == .available)
    }

    @Test func unavailableWithoutAConversation() {
        let result = CompactAction.availability(isWorking: false, isRestarting: false, hasConversation: false)
        #expect(result == .unavailable(reason: "Nothing to compact yet"))
    }

    @Test func unavailableWhileATurnRunsOrRestarts() {
        let reason = CompactAction.Availability.unavailable(reason: "Wait for the current turn to finish")
        #expect(CompactAction.availability(isWorking: true, isRestarting: false, hasConversation: true) == reason)
        #expect(CompactAction.availability(isWorking: false, isRestarting: true, hasConversation: true) == reason)
    }
}
