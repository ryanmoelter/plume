import Foundation
import Testing
@testable import Plume

/// What a headless tab reports it is waiting on, given the requests still
/// outstanding. The reason is decoded from the request that raised it, so
/// these cover each of the three tools a request can be.
@MainActor
struct HeadlessAttentionStatusTests {
    private func permission(
        id: String = UUID().uuidString,
        tool: String,
        input: [String: JSONValue] = [:]
    ) -> PendingPermission {
        PendingPermission(
            id: id,
            toolName: tool,
            displayName: tool,
            input: input,
            description: nil,
            decisionReason: nil,
            toolUseID: nil,
            agentID: nil,
            interactive: InteractiveToolPayload.decoding(name: tool, input: input)
        )
    }

    private var plan: PendingPermission {
        permission(tool: "ExitPlanMode", input: ["plan": .string("# Do the thing")])
    }

    private var question: PendingPermission {
        permission(tool: "AskUserQuestion", input: ["questions": .array([
            .object(["question": .string("Which one?"), "header": .string("Pick")]),
        ])])
    }

    @Test func nothingPendingWantsNothing() {
        #expect(HeadlessSession.attentionStatus(for: []) == nil)
    }

    @Test func aPlanWaitsForApproval() {
        #expect(HeadlessSession.attentionStatus(for: [plan]) == .planApproval)
    }

    @Test func aQuestionSaysItWasAsked() {
        #expect(HeadlessSession.attentionStatus(for: [question]) == .questionAsked)
    }

    @Test func anyOtherToolJustNeedsPermission() {
        #expect(HeadlessSession.attentionStatus(for: [permission(tool: "Bash")]) == .permissionNeeded)
    }

    /// An `ExitPlanMode` carrying no plan cannot be drawn as one, so it falls
    /// back to a plain permission rather than promising a panel with nothing
    /// in it.
    @Test func aPlanlessExitPlanModeIsJustAPermission() {
        #expect(HeadlessSession.attentionStatus(for: [permission(tool: "ExitPlanMode")]) == .permissionNeeded)
    }

    /// Several requests can be outstanding at once, and the answer that
    /// decides the most is the one worth naming.
    @Test func thePlanOutranksEverythingElsePending() {
        #expect(HeadlessSession.attentionStatus(for: [permission(tool: "Bash"), question, plan]) == .planApproval)
        #expect(HeadlessSession.attentionStatus(for: [plan, permission(tool: "Bash")]) == .planApproval)
    }

    @Test func aQuestionOutranksAPlainPermission() {
        #expect(HeadlessSession.attentionStatus(for: [permission(tool: "Bash"), question]) == .questionAsked)
    }

    /// Arrival order must not decide the reason — the same set reads the same
    /// either way round.
    @Test func theOrderRequestsArrivedInDoesNotMatter() {
        let forwards = HeadlessSession.attentionStatus(for: [question, permission(tool: "Bash"), plan])
        let backwards = HeadlessSession.attentionStatus(for: [plan, permission(tool: "Bash"), question])
        #expect(forwards == backwards)
    }

    @Test func everyReasonItReportsWantsAttention() {
        for pending in [[plan], [question], [permission(tool: "Bash")]] {
            let status = HeadlessSession.attentionStatus(for: pending)
            #expect(status?.wantsAttention == true)
        }
    }
}
