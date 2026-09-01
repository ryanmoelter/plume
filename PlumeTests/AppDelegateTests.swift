import Testing
@testable import Plume

@MainActor
struct AppDelegateTests {
    @Test func noTabsNeverConfirms() {
        #expect(AppDelegate.shouldConfirmQuit(statuses: []) == false)
    }

    @Test func idleAndDoneTabsDoNotConfirm() {
        #expect(AppDelegate.shouldConfirmQuit(statuses: [.idle, .done, .unset]) == false)
    }

    @Test func aWorkingTabConfirms() {
        #expect(AppDelegate.shouldConfirmQuit(statuses: [.idle, .working]) == true)
    }

    @Test func aTabNeedingInputConfirms() {
        #expect(AppDelegate.shouldConfirmQuit(statuses: [.needsInput]) == true)
    }

    @Test func errorAloneDoesNotConfirm() {
        #expect(AppDelegate.shouldConfirmQuit(statuses: [.error]) == false)
    }
}
