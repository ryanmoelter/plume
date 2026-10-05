import Testing
@testable import Plume

struct KeyboardRemovalTests {
    @Test func deleteKeyArchivesStartedTask() {
        #expect(KeyboardRemoval.verbForDeleteKey(hasNeverStarted: false) == .archive)
    }

    @Test func deleteKeyDeletesNeverStartedTask() {
        #expect(KeyboardRemoval.verbForDeleteKey(hasNeverStarted: true) == .delete)
    }

    @Test func closeDeletesOnlyEmptyTask() {
        #expect(KeyboardRemoval.deletesTaskOnClose(tabCount: 0))
        #expect(!KeyboardRemoval.deletesTaskOnClose(tabCount: 2))
    }
}
