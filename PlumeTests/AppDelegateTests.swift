import Testing
@testable import Plume

@MainActor
struct AppDelegateTests {
    @Test func noTabsNeverConfirms() {
        #expect(AppDelegate.shouldConfirmQuit(
            statuses: [],
            isSystemInitiated: false,
            confirmUserQuit: true,
            confirmSystemQuit: true
        ) == false)
    }

    @Test func settledTabsDoNotConfirm() {
        #expect(AppDelegate.shouldConfirmQuit(
            statuses: [.awaitingReply, .awaitingReply, .notStarted],
            isSystemInitiated: false,
            confirmUserQuit: true,
            confirmSystemQuit: true
        ) == false)
    }

    @Test func aWorkingTabConfirmsWhenUserInitiatedAndSettingOn() {
        #expect(AppDelegate.shouldConfirmQuit(
            statuses: [.awaitingReply, .working],
            isSystemInitiated: false,
            confirmUserQuit: true,
            confirmSystemQuit: true
        ) == true)
    }

    @Test func aTabNeedingInputConfirmsWhenUserInitiatedAndSettingOn() {
        #expect(AppDelegate.shouldConfirmQuit(
            statuses: [.permissionNeeded],
            isSystemInitiated: false,
            confirmUserQuit: true,
            confirmSystemQuit: true
        ) == true)
    }

    @Test func errorAloneDoesNotConfirm() {
        #expect(AppDelegate.shouldConfirmQuit(
            statuses: [.error],
            isSystemInitiated: false,
            confirmUserQuit: true,
            confirmSystemQuit: true
        ) == false)
    }

    @Test func userInitiatedQuitDoesNotConfirmWhenSettingOff() {
        #expect(AppDelegate.shouldConfirmQuit(
            statuses: [.working],
            isSystemInitiated: false,
            confirmUserQuit: false,
            confirmSystemQuit: true
        ) == false)
    }

    @Test func systemInitiatedQuitDoesNotConfirmByDefault() {
        #expect(AppDelegate.shouldConfirmQuit(
            statuses: [.working],
            isSystemInitiated: true,
            confirmUserQuit: true,
            confirmSystemQuit: false
        ) == false)
    }

    @Test func systemInitiatedQuitConfirmsWhenSettingOn() {
        #expect(AppDelegate.shouldConfirmQuit(
            statuses: [.working],
            isSystemInitiated: true,
            confirmUserQuit: true,
            confirmSystemQuit: true
        ) == true)
    }

    @Test func systemInitiatedQuitIgnoresUserSetting() {
        #expect(AppDelegate.shouldConfirmQuit(
            statuses: [.working],
            isSystemInitiated: true,
            confirmUserQuit: false,
            confirmSystemQuit: true
        ) == true)
    }

    @Test func userInitiatedQuitIgnoresSystemSetting() {
        #expect(AppDelegate.shouldConfirmQuit(
            statuses: [.working],
            isSystemInitiated: false,
            confirmUserQuit: true,
            confirmSystemQuit: false
        ) == true)
    }
}
