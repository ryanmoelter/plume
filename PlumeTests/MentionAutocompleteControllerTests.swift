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

    @Test func aFilterPrefixListsFiftyOfItsSource() async {
        sources.fileAnswer = { _ in (0..<60).map { MentionFixtures.ranked(.file(MentionFixtures.file("src/f\($0).swift"))) } }
        sources.linearAnswer = { _ in (0..<60).map { MentionFixtures.ranked(.linear(MentionFixtures.issue("DROID-\($0)", "x"))) } }
        let controller = makeController()

        type("@file:src/", into: controller)
        await controller.settled()
        #expect(controller.candidates.count == 50)

        type("@linear:x", into: controller)
        await controller.settled()
        #expect(controller.candidates.count == 50)
        #expect(sources.linearLimits.allSatisfy { $0 == 50 })

        type("@x", into: controller)
        await controller.settled()
        #expect(sources.linearLimits.last == FileMentionMatcher.defaultLimit)
        #expect(controller.candidates.count == MentionRanker.perSourceLimit + MentionRanker.fileLimit)
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
        sources.holdsPullRequests = true
        let second = MentionFixtures.file("drop.txt")
        sources.fileAnswer = { _ in
            [MentionFixtures.ranked(.file(MentionFixtures.file("dro.txt"))), MentionFixtures.ranked(.file(second))]
        }
        let controller = makeController()
        defer { sources.releaseAll() }

        type("@dro", into: controller)
        await sources.waitForHeldPullRequests(2)
        for _ in 0..<1_000 where controller.candidates.count < 2 { await Task.yield() }
        controller.moveSelection(by: 1)
        #expect(controller.selectedIndex == 1)

        let pull = MentionFixtures.ranked(.pullRequest(MentionFixtures.pull(3, "Drop it")))
        for call in sources.heldPullRequests { call.release([pull]) }
        await controller.settled()

        #expect(controller.candidates.first == pull.candidate)
        #expect(controller.selectedIndex == 2)
        #expect(controller.candidates[controller.selectedIndex] == .file(second))
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

    @Test func acceptingReplacesTheTokenWithAReferenceAndResolvesIt() async {
        sources.linearAnswer = { _ in [MentionFixtures.ranked(.linear(MentionFixtures.issue("DROID-1", "Layout")))] }
        let controller = makeController()
        var accepted: SlashCommandMatcher.AcceptedCommand?
        var resolved: (MentionReference.Kind, ResolvedMention)?
        controller.onAccept = { accepted = $0 }
        controller.onResolve = { resolved = ($0, $1) }

        type("see @dro", into: controller)
        await controller.settled()
        controller.acceptSelection()

        #expect(accepted?.text == "see @DROID-1 ")
        #expect(accepted?.caretLocation == ("see @DROID-1 " as NSString).length)
        #expect(resolved?.0 == .linear(identifier: "DROID-1"))
        #expect(resolved?.1.target == "https://linear.app/acme/issue/droid-1")
        #expect(resolved?.1.title == "Layout")
        #expect(!controller.isPresented)
    }

    @Test func anAcceptedReferenceDoesNotReopenTheMenuOnItself() async throws {
        sources.linearAnswer = { _ in [MentionFixtures.ranked(.linear(MentionFixtures.issue("DROID-1", "Layout")))] }
        let controller = makeController()
        var accepted: SlashCommandMatcher.AcceptedCommand?
        controller.onAccept = { accepted = $0 }

        controller.update(text: "(see @dro)", caretLocation: 9, directory: "/repo", isCommandMode: false)
        await controller.settled()
        controller.acceptSelection()
        let result = try #require(accepted)
        #expect(result.text == "(see @DROID-1)")

        controller.update(text: result.text, caretLocation: result.caretLocation, directory: "/repo", isCommandMode: false)
        #expect(controller.query == nil)
    }

    @Test func acceptingAFolderKeepsTheMenuOpenInsideIt() async {
        sources.fileAnswer = { query in
            query.text.hasSuffix("/")
                ? [MentionFixtures.ranked(.file(MentionFixtures.file("Plume/UI/Chat.swift")))]
                : [MentionFixtures.ranked(.file(MentionFixtures.file("Plume/UI", isDirectory: true)))]
        }
        let controller = makeController()
        var accepted: SlashCommandMatcher.AcceptedCommand?
        controller.onAccept = { accepted = $0 }

        type("see @UI", into: controller)
        await controller.settled()
        controller.acceptSelection()

        #expect(accepted?.text == "see @Plume/UI/")
        #expect(controller.query?.text == "Plume/UI/")
        await controller.settled()
        #expect(sources.fileQueries.last == "Plume/UI/")
        #expect(controller.candidates.map(\.id) == ["file:Plume/UI/Chat.swift"])
    }

    @Test func twoLettersOfAFilterOfferItFirst() async {
        sources.fileAnswer = { _ in [MentionFixtures.ranked(.file(MentionFixtures.file("lib.swift")))] }
        let controller = makeController()
        var accepted: SlashCommandMatcher.AcceptedCommand?
        controller.onAccept = { accepted = $0 }

        type("@li", into: controller)
        await controller.settled()
        #expect(controller.candidates.map(\.id) == ["filter:linear", "file:lib.swift"])

        let askedFiles = sources.fileQueries.count
        let askedPullRequests = sources.pullRequestQueries.count
        controller.acceptSelection()
        #expect(accepted?.text == "@linear:")
        #expect(controller.query?.filter == .linear)
        await controller.settled()
        #expect(sources.fileQueries.count == askedFiles)
        #expect(sources.pullRequestQueries.count == askedPullRequests)
    }
}
