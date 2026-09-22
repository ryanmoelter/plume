import Testing
import Foundation
@testable import Plume

/// The policy that decides when a headless conversation is titled: once when
/// it has something to describe, again when a plan describes it better, and
/// rarely after that. Never on a terminal tab, a user-named task, or a turn
/// still in flight.
struct SessionTitleRequesterTests {
    private func context(
        transport: AgentTransport = .headless,
        userTaskName: String? = nil,
        isWorking: Bool = false,
        openingMessage: String? = "Add OAuth2 login with Google to my Flask app",
        planFilePath: String? = nil,
        planTitle: String? = nil,
        hasExistingTitle: Bool = false
    ) -> SessionTitleRequester.Context {
        SessionTitleRequester.Context(
            transport: transport,
            userTaskName: userTaskName,
            isWorking: isWorking,
            openingMessage: openingMessage,
            planFilePath: planFilePath,
            planTitle: planTitle,
            hasExistingTitle: hasExistingTitle
        )
    }

    @Test
    func titlesFromTheOpeningMessageOnTheFirstTurn() {
        var requester = SessionTitleRequester()
        #expect(requester.descriptionForTitleRequest(context())
            == "Add OAuth2 login with Google to my Flask app")
    }

    @Test
    func doesNotTitleAgainOnTheNextTurn() {
        var requester = SessionTitleRequester()
        _ = requester.descriptionForTitleRequest(context())
        #expect(requester.descriptionForTitleRequest(context()) == nil)
    }

    @Test
    func neverTitlesAgainFromTheOpeningMessage() {
        var requester = SessionTitleRequester()
        _ = requester.descriptionForTitleRequest(context())
        for _ in 0..<20 {
            #expect(requester.descriptionForTitleRequest(context()) == nil)
        }
    }

    @Test
    func aPlanTitlesTheTabOverTheOpeningMessage() {
        var requester = SessionTitleRequester()
        let withPlan = context(planFilePath: "/tmp/plan.md", planTitle: "Generate a tab title")
        #expect(requester.descriptionForTitleRequest(withPlan) == "Generate a tab title")
    }

    @Test
    func theSamePlanTitlesOnlyOnce() {
        var requester = SessionTitleRequester()
        let withPlan = context(planFilePath: "/tmp/plan.md", planTitle: "Generate a tab title")
        _ = requester.descriptionForTitleRequest(withPlan)
        #expect(requester.descriptionForTitleRequest(withPlan) == nil)
    }

    @Test
    func aDifferentPlanTitlesAgain() {
        var requester = SessionTitleRequester()
        _ = requester.descriptionForTitleRequest(
            context(planFilePath: "/tmp/one.md", planTitle: "First")
        )
        #expect(requester.descriptionForTitleRequest(
            context(planFilePath: "/tmp/two.md", planTitle: "Second")
        ) == "Second")
    }

    /// A plan file exists from the moment the agent starts writing it, so a
    /// heading-less one must not consume the plan trigger.
    @Test
    func aPlanWithNoHeadingYetFallsBackToTheOpeningMessage() {
        var requester = SessionTitleRequester()
        let writing = context(planFilePath: "/tmp/plan.md", planTitle: nil)
        #expect(requester.descriptionForTitleRequest(writing)
            == "Add OAuth2 login with Google to my Flask app")

        var later = SessionTitleRequester()
        _ = later.descriptionForTitleRequest(writing)
        #expect(later.descriptionForTitleRequest(
            context(planFilePath: "/tmp/plan.md", planTitle: "Generate a tab title")
        ) == "Generate a tab title")
    }

    @Test
    func neverTitlesATerminalTab() {
        var requester = SessionTitleRequester()
        #expect(requester.descriptionForTitleRequest(context(transport: .terminal)) == nil)
    }

    @Test
    func neverTitlesAUserNamedTask() {
        var requester = SessionTitleRequester()
        #expect(requester.descriptionForTitleRequest(context(userTaskName: "Login work")) == nil)
    }

    @Test
    func aWhitespaceOnlyTaskNameDoesNotCountAsNamed() {
        var requester = SessionTitleRequester()
        #expect(requester.descriptionForTitleRequest(context(userTaskName: "   ")) != nil)
    }

    @Test
    func neverTitlesMidTurn() {
        var requester = SessionTitleRequester()
        #expect(requester.descriptionForTitleRequest(context(isWorking: true)) == nil)
    }

    /// A resumed conversation the TUI already named keeps that name.
    @Test
    func doesNotRetitleAResumedSessionOnItsFirstTurn() {
        var requester = SessionTitleRequester()
        #expect(requester.descriptionForTitleRequest(context(hasExistingTitle: true)) == nil)
    }

    @Test
    func aResumedSessionStillTitlesFromAPlan() {
        var requester = SessionTitleRequester()
        #expect(requester.descriptionForTitleRequest(context(
            planFilePath: "/tmp/plan.md",
            planTitle: "Generate a tab title",
            hasExistingTitle: true
        )) == "Generate a tab title")
    }

    /// `hasExistingTitle` means "a model already named this", not "the tab
    /// shows something". A fresh tab is labelled with its opening message the
    /// moment the transcript appears, and that must not pass for a title.
    @Test
    func titlesATabAlreadyLabelledWithItsOpeningMessage() {
        var requester = SessionTitleRequester()
        #expect(requester.descriptionForTitleRequest(context(hasExistingTitle: false)) != nil)
    }

    /// An empty description is answered with a null title, so it is not worth
    /// the round trip.
    @Test(arguments: [nil, "", "   "])
    func doesNotAskWithNothingToDescribe(message: String?) {
        var requester = SessionTitleRequester()
        #expect(requester.descriptionForTitleRequest(context(openingMessage: message)) == nil)
    }
}
