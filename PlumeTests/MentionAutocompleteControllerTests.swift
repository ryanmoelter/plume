import Foundation
import Testing
@testable import Plume

/// The mention menu's state machine against fake sources: which sources a
/// query asks, what a superseded or dismissed query leaves behind, and when
/// the menu owns the composer's keys.
@MainActor
struct MentionAutocompleteControllerTests {
    private let sources = FakeMentionSources()
    private let sleep = RecordingSleep()

    private func makeController() -> MentionAutocompleteController {
        MentionAutocompleteController(sources: sources, sleep: sleep.sleep, homeDirectory: "/Users/test")
    }

    private func type(_ text: String, into controller: MentionAutocompleteController, isCommandMode: Bool = false) {
        controller.update(
            text: text,
            caretLocation: (text as NSString).length,
            directory: "/repo",
            isCommandMode: isCommandMode
        )
    }

    @Test func aSupersededQuerysResultsAreDropped() async {
        sources.holdsFiles = true
        let controller = makeController()
        defer { sources.releaseAll() }

        type("@src/a", into: controller)
        type("@src/ab", into: controller)
        await sources.waitForHeldFiles(2)
        let stale = sources.heldFiles[0]
        let current = sources.heldFiles[1]

        current.release([MentionFixtures.ranked(.file(MentionFixtures.file("src/abc.swift")))])
        await controller.settled()
        stale.release([MentionFixtures.ranked(.file(MentionFixtures.file("src/stale.swift")))])
        await controller.discarded()

        #expect(controller.candidates.map(\.id) == ["file:src/abc.swift"])
    }

    @Test func escapeKeepsTheTokenClosedUntilTheCaretLeavesIt() async {
        sources.linearAnswer = { _ in [MentionFixtures.ranked(.linear(MentionFixtures.issue("DROID-1", "Layout")))] }
        let controller = makeController()

        type("@dro", into: controller)
        await controller.settled()
        #expect(controller.isShowing)

        controller.dismiss()
        #expect(!controller.isPresented)
        type("@drop", into: controller)
        #expect(!controller.isPresented)

        controller.update(text: "@drop", caretLocation: 0, directory: "/repo", isCommandMode: false)
        type("@drop", into: controller)
        await controller.settled()
        #expect(controller.isShowing)
    }

    @Test func aNewTriggerReopensAfterEscape() async {
        sources.linearAnswer = { _ in [MentionFixtures.ranked(.linear(MentionFixtures.issue("DROID-1", "Layout")))] }
        let controller = makeController()

        type("@dro", into: controller)
        await controller.settled()
        controller.dismiss()
        type("@dro @l", into: controller)
        await controller.settled()

        #expect(controller.isShowing)
        #expect(controller.query?.text == "l")
    }

    @Test func commandModeCloses() async {
        sources.linearAnswer = { _ in [MentionFixtures.ranked(.linear(MentionFixtures.issue("DROID-1", "Layout")))] }
        let controller = makeController()

        type("@dro", into: controller)
        await controller.settled()
        type("@dro", into: controller, isCommandMode: true)

        #expect(!controller.isPresented)
        #expect(!controller.isShowing)
    }

    @Test func aLoadingMenuTakesNoKeys() async {
        sources.holdsFiles = true
        let controller = makeController()
        let router = ComposerAutocompleteRouter(mention: controller)
        defer { sources.releaseAll() }

        type("@zz", into: controller)
        await sources.waitForHeldFiles(1)

        #expect(controller.isPresented)
        #expect(controller.isLoading)
        #expect(!controller.isShowing)
        #expect(!router.isShowing)
    }

    @Test func lateResultsKeepTheSelection() async {
        sources.holdsFiles = true
        let first = MentionFixtures.issue("DROID-1", "One")
        let second = MentionFixtures.issue("DROID-2", "Two")
        sources.linearAnswer = { _ in
            [MentionFixtures.ranked(.linear(first), .loose), MentionFixtures.ranked(.linear(second), .loose)]
        }
        let controller = makeController()
        defer { sources.releaseAll() }

        type("@dro", into: controller)
        await sources.waitForHeldFiles(1)
        for _ in 0..<1_000 where controller.candidates.count < 2 { await Task.yield() }
        controller.moveSelection(by: 1)
        #expect(controller.selectedIndex == 1)

        sources.heldFiles[0].release([MentionFixtures.ranked(.file(MentionFixtures.file("dro.txt")), .exact)])
        await controller.settled()

        #expect(controller.candidates.first?.id == "file:dro.txt")
        #expect(controller.selectedIndex == 2)
        #expect(controller.candidates[controller.selectedIndex] == .linear(second))
    }

    @Test func aMultiWordQueryWithNoResultsCloses() async {
        let controller = makeController()

        type("@foo bar", into: controller)
        await controller.settled()
        #expect(controller.query == nil)

        let asked = sources.fileQueries.count
        type("@foo barx", into: controller)
        #expect(controller.query == nil)
        #expect(sources.fileQueries.count == asked)
    }

    @Test func aOneWordQueryWithNoResultsStaysOpen() async {
        let controller = makeController()

        type("@foo", into: controller)
        await controller.settled()

        #expect(controller.query?.text == "foo")
        #expect(!controller.isPresented)
    }

    @Test func aHashAsksOnlyPullRequests() async {
        sources.pullRequestAnswer = { _ in [MentionFixtures.ranked(.pullRequest(MentionFixtures.pull(12, "Fix")))] }
        let controller = makeController()

        type("#12", into: controller)
        await controller.settled()

        #expect(sources.pullRequestQueries == ["12", "12"])
        #expect(sources.fileQueries.isEmpty)
        #expect(sources.linearSearches.isEmpty)
        #expect(controller.candidates.map(\.id) == ["pr:https://github.com/acme/app/pull/12"])
    }

    @Test func aPullRequestTitleSearchIsDebounced() async {
        let controller = makeController()

        type("#lay", into: controller)
        await controller.settled()

        #expect(sleep.durations == [MentionAutocompleteController.Debounce().pullRequestSearch])
        #expect(sources.pullRequestLookups == ["lay"])
    }

    @Test func aPullRequestNumberLookupIsDebouncedButTheListIsNot() async {
        let controller = makeController()

        type("#7", into: controller)
        await controller.settled()

        #expect(sleep.durations == [MentionAutocompleteController.Debounce().pullRequestNumber])
        #expect(sources.pullRequestQueries == ["7", "7"])
        #expect(sources.pullRequestLookups == ["7"])
    }

    @Test func aShortTitleTermAsksOnceWithNoDebounce() async {
        let controller = makeController()

        type("#la", into: controller)
        await controller.settled()

        #expect(sleep.durations.isEmpty)
        #expect(sources.pullRequestQueries == ["la"])
    }

    @Test func acceptingReplacesTheTokenWithALink() async {
        sources.linearAnswer = { _ in [MentionFixtures.ranked(.linear(MentionFixtures.issue("DROID-1", "Layout")))] }
        let controller = makeController()
        var accepted: SlashCommandMatcher.AcceptedCommand?
        controller.onAccept = { accepted = $0 }

        type("see @dro", into: controller)
        await controller.settled()
        controller.acceptSelection()

        let link = "[DROID-1](https://linear.app/acme/issue/droid-1)"
        #expect(accepted?.text == "see \(link) ")
        #expect(accepted?.caretLocation == ("see \(link) " as NSString).length)
        #expect(!controller.isPresented)
    }
}
