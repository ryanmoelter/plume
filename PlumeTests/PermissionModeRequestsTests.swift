import Testing
@testable import Plume

/// A refused `set_permission_mode` puts the picker back on the last mode the
/// CLI confirmed, but only when it was the latest request; everything else
/// keeps the optimistic choice.
struct PermissionModeRequestsTests {
    private func tracker(confirmed: PermissionMode) -> PermissionModeRequests {
        var requests = PermissionModeRequests()
        requests.confirm(confirmed)
        return requests
    }

    @Test func refusalRevertsToTheConfirmedMode() {
        var requests = tracker(confirmed: .acceptEdits)
        requests.didRequest(id: "plume-2")

        let outcome = requests.applyReply(requestID: "plume-2", mode: .bypassPermissions, isError: true)

        #expect(outcome == .revert(to: .acceptEdits))
    }

    @Test func successKeepsTheModeAndConfirmsIt() {
        var requests = tracker(confirmed: .acceptEdits)
        requests.didRequest(id: "plume-2")

        let outcome = requests.applyReply(requestID: "plume-2", mode: .plan, isError: false)

        #expect(outcome == .keep)
        #expect(requests.confirmed == .plan)
    }

    @Test func staleRefusalLeavesANewerChoiceAlone() {
        var requests = tracker(confirmed: .acceptEdits)
        requests.didRequest(id: "plume-2")
        requests.didRequest(id: "plume-3")

        let stale = requests.applyReply(requestID: "plume-2", mode: .bypassPermissions, isError: true)
        let latest = requests.applyReply(requestID: "plume-3", mode: .plan, isError: false)

        #expect(stale == .keep)
        #expect(latest == .keep)
        #expect(requests.confirmed == .plan)
    }

    @Test func refusalAfterAnAcceptedOlderRequestRevertsToThatOne() {
        var requests = tracker(confirmed: .acceptEdits)
        requests.didRequest(id: "plume-2")
        requests.didRequest(id: "plume-3")

        _ = requests.applyReply(requestID: "plume-2", mode: .plan, isError: false)
        let outcome = requests.applyReply(requestID: "plume-3", mode: .bypassPermissions, isError: true)

        #expect(outcome == .revert(to: .plan))
    }

    /// The mode showing before the latest request was itself refused, so it
    /// is not where the CLI is.
    @Test func refusalOfBothRequestsRevertsPastTheFirst() {
        var requests = tracker(confirmed: .acceptEdits)
        requests.didRequest(id: "plume-2")
        requests.didRequest(id: "plume-3")

        _ = requests.applyReply(requestID: "plume-2", mode: .bypassPermissions, isError: true)
        let outcome = requests.applyReply(requestID: "plume-3", mode: .auto, isError: true)

        #expect(outcome == .revert(to: .acceptEdits))
    }
}
