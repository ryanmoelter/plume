import Testing
@testable import Plume

/// The plan overlay's footer, which must follow the last proposal's answer
/// rather than the presence of a plan file.
struct PlanApprovalStateTests {
    @Test func noProposalIsNotApprovedYet() {
        #expect(PlanApprovalState.derive(latestProposal: nil) == .notApprovedYet)
    }

    @Test func anUnansweredProposalAwaitsADecision() {
        let proposal = PlanApprovalState.Proposal(toolUseID: "tool-1")
        #expect(PlanApprovalState.derive(latestProposal: proposal) == .awaitingDecision)
    }

    @Test func anApprovedProposalReadsApproved() {
        let proposal = PlanApprovalState.Proposal(toolUseID: "tool-1", decision: .approved)
        #expect(PlanApprovalState.derive(latestProposal: proposal) == .approved)
    }

    /// A rejection is not called out, because the plan may have been rewritten
    /// since — so it collapses into the same state as never having proposed.
    @Test func aRejectedProposalReadsTheSameAsNoProposal() {
        let proposal = PlanApprovalState.Proposal(toolUseID: "tool-1", decision: .rejected)
        #expect(PlanApprovalState.derive(latestProposal: proposal) == .notApprovedYet)
        #expect(PlanApprovalState.derive(latestProposal: proposal)
            == PlanApprovalState.derive(latestProposal: nil))
    }

    /// Only the newest proposal decides the footer: a fresh proposal after an
    /// approval puts the footer back to awaiting a decision.
    @Test func aNewProposalSupersedesAnEarlierApproval() {
        let reproposed = PlanApprovalState.Proposal(toolUseID: "tool-2")
        #expect(PlanApprovalState.derive(latestProposal: reproposed) == .awaitingDecision)
    }

    @Test func onlyAnAwaitingDecisionShowsTheApprovalOptions() {
        #expect(PlanApprovalState.awaitingDecision.showsApprovalOptions)
        #expect(!PlanApprovalState.approved.showsApprovalOptions)
        #expect(!PlanApprovalState.notApprovedYet.showsApprovalOptions)
    }

    @Test func onlySettledStatesCarryAFooterLabel() {
        #expect(PlanApprovalState.awaitingDecision.footerLabel == nil)
        #expect(PlanApprovalState.approved.footerLabel == "Approved")
        #expect(PlanApprovalState.notApprovedYet.footerLabel == "Not approved yet")
    }
}

/// The one-line stand-in the inline row shows in place of the whole plan.
struct PlanSummaryTests {
    @Test func takesTheFirstLine() {
        #expect(PlanSummary.firstLine(of: "Rewrite the parser\n\nThen the tests.")
            == "Rewrite the parser")
    }

    @Test func stripsAHeadingMarker() {
        #expect(PlanSummary.firstLine(of: "## Rewrite the parser\nDetails.")
            == "Rewrite the parser")
    }

    @Test func skipsLeadingBlankLines() {
        #expect(PlanSummary.firstLine(of: "\n\n   \nRewrite the parser")
            == "Rewrite the parser")
    }

    /// The row must never render empty, however little the plan carries.
    @Test func fallsBackWhenThereIsNoUsableLine() {
        #expect(PlanSummary.firstLine(of: "") == "Plan")
        #expect(PlanSummary.firstLine(of: "   \n\n  ") == "Plan")
        #expect(PlanSummary.firstLine(of: "###") == "Plan")
    }
}

/// The plan's own name, which the minimized dock bar shows beside the file
/// name.
struct PlanTitleTests {
    @Test func takesTheTopLevelHeading() {
        #expect(PlanSummary.title(of: "# Rewrite the parser\n\nThen the tests.")
            == "Rewrite the parser")
    }

    @Test func skipsProseAheadOfTheHeading() {
        #expect(PlanSummary.title(of: "A note.\n\n## Rewrite the parser\nDetails.")
            == "Rewrite the parser")
    }

    /// A plan file exists before anything writes to it, so the bar falls back
    /// to the file name rather than showing nothing.
    @Test func aPlanWithNoHeadingHasNoTitle() {
        #expect(PlanSummary.title(of: "") == nil)
        #expect(PlanSummary.title(of: "Rewrite the parser\nDetails.") == nil)
        #expect(PlanSummary.title(of: "#hashtag\n") == nil)
        #expect(PlanSummary.title(of: "###\n") == nil)
    }

    @Test func anEmptyHeadingYieldsToTheNextOne() {
        #expect(PlanSummary.title(of: "#  \n## Rewrite the parser") == "Rewrite the parser")
    }
}

/// While a proposal is live the overlay may only be minimized, so the
/// approval options cannot leave the screen with the request still open.
struct PlanClosabilityTests {
    @Test func anUndecidedPlanCannotBeClosed() {
        #expect(!PlanApprovalState.awaitingDecision.isClosable)
    }

    @Test func anAnsweredPlanCanBeClosed() {
        #expect(PlanApprovalState.approved.isClosable)
        #expect(PlanApprovalState.notApprovedYet.isClosable)
    }
}
