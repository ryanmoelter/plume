import Testing
@testable import Plume

/// A proposed-plan row opens its own plan, read-only once settled, with a
/// footer saying how it was answered.
@MainActor
struct ProposedPlanTests {
    private func call(interactive: InteractiveToolPayload?, result: String? = nil) -> ToolCall {
        ToolCall(
            id: "plan-1",
            name: "ExitPlanMode",
            summary: ToolCallSummary(name: "ExitPlanMode", detail: ""),
            input: .json("{}"),
            interactive: interactive,
            result: result
        )
    }

    private func settled(_ resultText: String?) -> ProposedPlan {
        ProposedPlan(id: "p", markdown: "# Plan", filePath: nil, isPending: false, resultText: resultText)
    }

    @Test func carriesTheRowsOwnMarkdown() throws {
        let plan = try #require(ProposedPlan(
            call: call(interactive: .plan(markdown: "# Old plan", filePath: "/tmp/old.md"), result: "ok"),
            isPending: false
        ))
        #expect(plan.id == "plan-1")
        #expect(plan.markdown == "# Old plan")
        #expect(plan.filePath == "/tmp/old.md")
        #expect(plan.resultText == "ok")
    }

    @Test func aQuestionIsNotAPlan() {
        #expect(ProposedPlan(call: call(interactive: .questions([])), isPending: false) == nil)
        #expect(ProposedPlan(call: call(interactive: nil), isPending: false) == nil)
    }

    @Test func aPendingPlanHasNoSettledLabel() {
        let plan = ProposedPlan(id: "p", markdown: "", filePath: nil, isPending: true, resultText: nil)
        #expect(plan.settledLabel == nil)
    }

    @Test func anUnansweredPlanHasNoSettledLabel() {
        #expect(settled(nil).settledLabel == nil)
    }

    @Test func anApprovalReadsApproved() {
        #expect(settled("User has approved your plan.").settledLabel == "Approved")
    }

    @Test func aFailedResultWithoutPlumesMarkerIsNotApproved() {
        let plan = ProposedPlan(
            id: "p", markdown: "", filePath: nil, isPending: false,
            resultText: "[Request interrupted by user]", didFail: true
        )
        #expect(plan.settledLabel == "Not approved")
    }

    @Test func carriesTheCallsFailure() throws {
        var failed = call(interactive: .plan(markdown: "# Plan", filePath: nil), result: "denied")
        failed.didFail = true
        #expect(try #require(ProposedPlan(call: failed, isPending: false)).didFail)
    }

    @Test func aRejectionCarriesItsReason() {
        #expect(settled(PlanResolution.denialMessage(reason: "too broad")).settledLabel == "Rejected: too broad")
        #expect(settled(PlanResolution.denialMessage(reason: "")).settledLabel == "Rejected")
    }
}
