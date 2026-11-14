import Foundation
import Testing
@testable import Plume

/// An `offer` call waits on the user's answer. Its card reads from Plume's
/// live board while the call waits, and from the call's result once it has
/// one, so a relaunched chat still says what became of each offer. The board
/// takes one answer per offer: a second click, or a click after the call
/// stopped waiting, does nothing.
@MainActor
struct ChildSessionOfferTests {
    private static let sessionID = "0B6F9A1E-2F4C-4D1A-9C55-3E8A7D2B1F00"

    private func request(title: String = "Fix login") -> StartSessionRequest {
        let arguments: [String: JSONValue] = [
            "initiation": .string("offer"), "title": .string(title), "prompt": .string("Fix it")
        ]
        return try! StartSessionRequest.parse(arguments).get()
    }

    private func call(_ arguments: String, name: String = PlumeMCPTool.startSession.qualifiedName) -> ToolCall {
        ToolCall(id: "toolu_1", name: name, summary: ToolCallSummary(name: name), input: .json(arguments))
    }

    // MARK: - Formats

    @Test func aStartedResultNamesItsSession() throws {
        // A title that itself looks like a started result must not win.
        let title = "Mimic (session_id: \(UUID().uuidString), name: wrong). It runs on its own"
        let text = ChildSessionFormats.started(title: title, sessionID: Self.sessionID, name: "fix-login", notesFolder: "/n")
        let started = try #require(ChildSessionFormats.startedSession(in: text))
        #expect(started.sessionID == Self.sessionID)
        #expect(started.name == "fix-login")
        #expect(ChildSessionFormats.startedSession(in: ChildSessionFormats.offerWithdrawn) == nil)
    }

    @Test func onlyAnOfferWithoutAProposalIDHasOfferArguments() throws {
        let offer = try #require(ChildSessionFormats.offerArguments(of: call(
            #"{"initiation":"offer","title":"Fix login","prompt":"Fix it"}"#
        )))
        #expect(offer.title == "Fix login")
        #expect(offer.prompt == "Fix it")
        #expect(ChildSessionFormats.offerArguments(of: call(#"{"initiation":"own_initiative","title":"T","prompt":"P"}"#)) == nil)
        #expect(ChildSessionFormats.offerArguments(of: call(#"{"initiation":"offer","proposal_id":"task_0000abcd"}"#)) == nil)
        #expect(ChildSessionFormats.offerArguments(of: call(#"{"initiation":"offer"}"#, name: "mcp__other__start_session")) == nil)
    }

    // MARK: - Card state

    @Test func aLiveOfferReadsAsTheBoardHoldsIt() {
        #expect(ChildSessionOfferCardState.reading(live: .starting, result: nil, didFail: false, isTurnRunning: false) == .starting)
    }

    @Test func anOfferWithNoResultWaitsWhileTheTurnRunsAndIsNeverAnsweredAfter() {
        #expect(ChildSessionOfferCardState.reading(live: nil, result: nil, didFail: false, isTurnRunning: true) == .waiting)
        #expect(ChildSessionOfferCardState.reading(live: nil, result: nil, didFail: false, isTurnRunning: false) == .unanswered)
    }

    @Test func aResultSaysWhatBecameOfTheOffer() {
        let started = ChildSessionFormats.started(title: "Fix login", sessionID: Self.sessionID, name: "fix-login", notesFolder: "/n")
        let declined = ChildSessionFormats.offerDeclined(title: "Fix login")
        let interrupted = "The user doesn't want to proceed with this tool use. The tool use was rejected."
        func read(_ result: String, didFail: Bool = false) -> ChildSessionOfferCardState? {
            ChildSessionOfferCardState.reading(live: nil, result: result, didFail: didFail, isTurnRunning: false)
        }

        #expect(read(started) == .started(sessionID: Self.sessionID, name: "fix-login"))
        #expect(read(declined) == .declined)
        #expect(read(ChildSessionFormats.offerWithdrawn, didFail: true) == .withdrawn)
        #expect(read(interrupted, didFail: true) == .withdrawn)
        #expect(read("title is required", didFail: true) == nil)
    }

    // MARK: - Board

    @Test func anAnswerReachesTheWaitingCall() async {
        let board = ChildSessionOfferBoard()
        board.raise("toolu_1", parentTabID: UUID(), request: request())
        board.answer("toolu_1", .doItHere)
        #expect(await board.nextAction("toolu_1") == .doItHere)
    }

    @Test func onlyAPendingOfferTakesTheUsersAnswer() async {
        let board = ChildSessionOfferBoard()
        board.raise("toolu_1", parentTabID: UUID(), request: request())
        board.setStarting("toolu_1")
        board.answer("toolu_1", .newSession)
        board.answer("toolu_1", .withdraw)
        #expect(await board.nextAction("toolu_1") == .withdraw)

        board.settle("toolu_1", .declined, result: "done")
        board.answer("toolu_1", .newSession)
        #expect(board.offer("toolu_1")?.state == .declined)
    }

    @Test func aFailedStartReturnsTheCardToPendingWithTheReason() {
        let board = ChildSessionOfferBoard()
        board.raise("toolu_1", parentTabID: UUID(), request: request())
        board.setStarting("toolu_1")
        board.fail("toolu_1", "No folder")
        #expect(board.offer("toolu_1")?.state == .pending)
        #expect(board.offer("toolu_1")?.failure == "No folder")
        board.setStarting("toolu_1")
        #expect(board.offer("toolu_1")?.failure == nil)
    }

    @Test func endingATabWithdrawsOnlyItsLiveOffers() async {
        let board = ChildSessionOfferBoard()
        let tab = UUID()
        board.raise("mine", parentTabID: tab, request: request())
        board.raise("other", parentTabID: UUID(), request: request())
        board.raise("settled", parentTabID: tab, request: request())
        board.settle("settled", .declined, result: "done")

        board.forget(tab)

        #expect(await board.nextAction("mine") == .withdraw)
        #expect(board.offer("settled") == nil)
        #expect(board.offer("other")?.state == .pending)
    }
}
