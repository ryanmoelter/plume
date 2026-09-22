import Foundation
import Testing

@testable import Plume

@MainActor
struct DraftStoreTests {
    @Test func remembersADraftPerTab() {
        let store = DraftStore()
        let first = UUID()
        let second = UUID()

        store.setDraft("half a thought", forTab: first)

        #expect(store.draft(forTab: first) == "half a thought")
        #expect(store.draft(forTab: second) == "")
    }

    @Test func emptyTextClearsTheDraft() {
        let store = DraftStore()
        let tab = UUID()
        store.setDraft("typed", forTab: tab)

        store.setDraft("", forTab: tab)

        #expect(store.draft(forTab: tab) == "")
    }

    @Test func forgettingATabDropsItsDraft() {
        let store = DraftStore()
        let kept = UUID()
        let closed = UUID()
        store.setDraft("kept", forTab: kept)
        store.setDraft("closed", forTab: closed)

        store.forget(tabID: closed)

        #expect(store.draft(forTab: closed) == "")
        #expect(store.draft(forTab: kept) == "kept")
    }

    /// Command mode outlives an empty draft: clearing the text to retype a
    /// command must not drop the user back into prose.
    @Test func commandModeSurvivesAnEmptiedDraft() {
        let store = DraftStore()
        let tab = UUID()
        store.setCommandMode(true, forTab: tab)
        store.setDraft("ls", forTab: tab)

        store.setDraft("", forTab: tab)

        #expect(store.isCommandMode(forTab: tab))
    }

    @Test func forgettingATabLeavesCommandMode() {
        let store = DraftStore()
        let tab = UUID()
        store.setCommandMode(true, forTab: tab)

        store.forget(tabID: tab)

        #expect(!store.isCommandMode(forTab: tab))
    }
}
