import Foundation
import SwiftData
import Testing
@testable import Plume

/// An `offer` call waits on the user's answer. Its card reads from Plume's
/// live board while the call waits, and from the call's result once it has
/// one, so a relaunched chat still says what became of each offer. The board
/// takes one answer per offer: a second click, or a click after the call
/// stopped waiting, does nothing. A withdrawal before the launch begins
/// starts nothing; one during the launch lets the child start and tells the
/// parent.
@MainActor
struct ChildSessionOfferTests {
    private static let sessionID = "0B6F9A1E-2F4C-4D1A-9C55-3E8A7D2B1F00"
    private let context: ModelContext

    init() throws {
        context = ModelContext(try ModelContainer(
            for: Schema([TaskGroup.self, WorkTask.self, TaskTab.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        ))
    }

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
        #expect(ChildSessionOfferCardState.reading(live: .starting, result: nil, didFail: false, isPending: false) == .starting)
    }

    @Test func anOfferWithNoResultWaitsWhileTheCallIsPendingAndIsNeverAnsweredAfter() {
        #expect(ChildSessionOfferCardState.reading(live: nil, result: nil, didFail: false, isPending: true) == .waiting)
        #expect(ChildSessionOfferCardState.reading(live: nil, result: nil, didFail: false, isPending: false) == .unanswered)
    }

    @Test func aResultSaysWhatBecameOfTheOffer() {
        let started = ChildSessionFormats.started(title: "Fix login", sessionID: Self.sessionID, name: "fix-login", notesFolder: "/n")
        let declined = ChildSessionFormats.offerDeclined(title: "Fix login")
        let interrupted = "The user doesn't want to proceed with this tool use. The tool use was rejected."
        func read(_ result: String, didFail: Bool = false) -> ChildSessionOfferCardState? {
            ChildSessionOfferCardState.reading(live: nil, result: result, didFail: didFail, isPending: false)
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

    @Test func aSecondClickBeforeTheCallTakesTheFirstIsIgnoredAndNotReplayedAfterAFailure() async {
        let board = ChildSessionOfferBoard()
        board.raise("toolu_1", parentTabID: UUID(), request: request())
        board.answer("toolu_1", .newSession)
        board.answer("toolu_1", .newSession)
        board.answer("toolu_1", .doItHere)
        #expect(board.offer("toolu_1")?.state == .starting)
        #expect(await board.nextAction("toolu_1") == .newSession)

        board.fail("toolu_1", "No folder")
        board.answer("toolu_1", .doItHere)
        #expect(await board.nextAction("toolu_1") == .doItHere)
    }

    @Test func aTurnEndingWithdrawsAnOfferTheUserAnsweredButTheCallHasNotTaken() {
        let board = ChildSessionOfferBoard()
        let tab = UUID()
        board.raise("toolu_1", parentTabID: tab, request: request())
        board.answer("toolu_1", .doItHere)
        board.withdrawAll(inTab: tab)
        #expect(board.isWithdrawn("toolu_1"))
    }

    // MARK: - Attention

    @Test func aPendingOfferMakesTheTabNeedTheUser() {
        let engine = StatusEngine()
        let session = HeadlessSession(tabID: UUID(), taskID: UUID(), statusEngine: engine)
        session.setOffer("toolu_1", waitsForUser: true)
        #expect(engine.status(forTab: session.tabID) == .questionAsked)
        session.setOffer("toolu_1", waitsForUser: false)
        #expect(engine.status(forTab: session.tabID) == .awaitingReply)
    }

    @Test func aPendingOfferRanksAsAQuestion() {
        #expect(HeadlessSession.attentionStatus(for: [], hasPendingOffer: true) == .questionAsked)
        #expect(HeadlessSession.attentionStatus(for: [], hasPendingOffer: false) == nil)
    }

    // MARK: - Awaiting the answer

    private final class Launches {
        var count = 0
    }

    private struct Offer {
        let task: WorkTask
        let parent: TaskTab
        let id = "toolu_\(UUID().uuidString)"
    }

    private func raiseOffer() throws -> Offer {
        let task = TaskStore.createTask(in: context, title: "Task", siblings: [])
        let parent = try #require(task.tabs.first)
        parent.permissionMode = .acceptEdits
        try context.save()
        let offer = Offer(task: task, parent: parent)
        #expect(ChildSessionCoordinator.shared.raiseOffer(request(), from: parent, toolUseID: offer.id) == nil)
        return offer
    }

    private func launcher(
        _ launches: Launches, _ offer: Offer, during: @escaping @MainActor (Int) -> Result<Void, ChildSessionError> = { _ in .success(()) }
    ) -> ChildSessionCoordinator.ChildLauncher {
        { [context] _, parent in
            launches.count += 1
            switch during(launches.count) {
            case .success: return .success(TaskStore.addChildTab(to: offer.task, parent: parent, in: context))
            case .failure(let error): return .failure(error)
            }
        }
    }

    private func awaitOffer(_ offer: Offer, launch: @escaping ChildSessionCoordinator.ChildLauncher) -> Task<Result<String, ChildSessionError>, Never> {
        let request = request()
        return Task { await ChildSessionCoordinator.shared.awaitOffer(request, from: offer.parent, toolUseID: offer.id, launch: launch) }
    }

    private func settle(_ condition: () -> Bool) async {
        for _ in 0..<1_000 where !condition() { await Task.yield() }
    }

    private var board: ChildSessionOfferBoard { .shared }

    @Test func cancellingTheCallWithdrawsTheOffer() async throws {
        let offer = try raiseOffer()
        defer { ChildSessionCoordinator.shared.tabForgotten(offer.parent.id) }
        let launches = Launches()
        let waiting = awaitOffer(offer, launch: launcher(launches, offer))

        waiting.cancel()

        #expect(await waiting.value == .failure(.failed(ChildSessionFormats.offerWithdrawn)))
        #expect(board.offer(offer.id)?.state == .withdrawn)
        #expect(launches.count == 0)
    }

    @Test func aWithdrawalBeforeTheLaunchBeginsStartsNothing() async throws {
        let offer = try raiseOffer()
        defer { ChildSessionCoordinator.shared.tabForgotten(offer.parent.id) }
        let launches = Launches()
        let waiting = awaitOffer(offer, launch: launcher(launches, offer))

        board.answer(offer.id, .newSession)
        board.answer(offer.id, .withdraw)

        #expect(await waiting.value == .failure(.failed(ChildSessionFormats.offerWithdrawn)))
        #expect(board.offer(offer.id)?.state == .withdrawn)
        #expect(launches.count == 0)
    }

    @Test func doingItHereThenCancellingReadsWithdrawn() async throws {
        let offer = try raiseOffer()
        defer { ChildSessionCoordinator.shared.tabForgotten(offer.parent.id) }
        let waiting = awaitOffer(offer, launch: launcher(Launches(), offer))
        await settle { false }

        board.answer(offer.id, .doItHere)
        waiting.cancel()

        #expect(await waiting.value == .failure(.failed(ChildSessionFormats.offerWithdrawn)))
        #expect(board.offer(offer.id)?.state == .withdrawn)
    }

    @Test func aFailedLaunchWaitsForANewClickWithoutReplayingOne() async throws {
        let offer = try raiseOffer()
        defer { ChildSessionCoordinator.shared.tabForgotten(offer.parent.id) }
        let launches = Launches()
        let board = board
        let waiting = awaitOffer(offer, launch: launcher(launches, offer) { attempt in
            guard attempt == 1 else { return .success(()) }
            board.answer(offer.id, .newSession)
            return .failure(.failed("No folder"))
        })

        board.answer(offer.id, .newSession)
        await settle { board.offer(offer.id)?.failure != nil }
        await settle { false }

        #expect(launches.count == 1)
        #expect(board.offer(offer.id)?.state == .pending)
        #expect(board.offer(offer.id)?.failure == "No folder")

        board.answer(offer.id, .newSession)
        guard case .success = await waiting.value else {
            Issue.record("expected the retry to start the session")
            return
        }
        #expect(launches.count == 2)
    }

    @Test func aWithdrawalDuringTheLaunchStartsTheChildAndTellsTheParent() async throws {
        let offer = try raiseOffer()
        let session = HeadlessSession(tabID: offer.parent.id, taskID: offer.task.id)
        ChildSessionCoordinator.shared.attach(to: session, task: offer.task, tab: offer.parent)
        defer { ChildSessionCoordinator.shared.tabForgotten(offer.parent.id) }
        let launches = Launches()
        let board = board
        let waiting = awaitOffer(offer, launch: launcher(launches, offer) { _ in
            board.answer(offer.id, .withdraw)
            return .success(())
        })

        board.answer(offer.id, .newSession)

        guard case .success = await waiting.value else {
            Issue.record("expected the child to start")
            return
        }
        guard case .started = board.offer(offer.id)?.state else {
            Issue.record("expected the card to read started")
            return
        }
        let preamble = try #require(session.userMessagePreamble?())
        #expect(preamble.contains("started your offered session"))
        #expect(preamble.contains("offer_started"))
    }

    @Test func theTurnEndingWithdrawsTheOffer() async throws {
        let offer = try raiseOffer()
        defer { ChildSessionCoordinator.shared.tabForgotten(offer.parent.id) }
        let launches = Launches()
        let waiting = awaitOffer(offer, launch: launcher(launches, offer))
        await settle { false }

        ChildSessionCoordinator.shared.simulateTurnFinished(in: offer.parent, text: "Done", hostDriven: false)

        #expect(await waiting.value == .failure(.failed(ChildSessionFormats.offerWithdrawn)))
        #expect(board.offer(offer.id)?.state == .withdrawn)
        #expect(launches.count == 0)
    }

    @Test func anOfferWithoutAToolUseIDFailsWithoutACard() async throws {
        let task = TaskStore.createTask(in: context, title: "Task", siblings: [])
        let parent = try #require(task.tabs.first)
        parent.permissionMode = .acceptEdits
        try context.save()
        let session = HeadlessSession(tabID: parent.id, taskID: task.id)
        ChildSessionCoordinator.shared.attach(to: session, task: task, tab: parent)
        defer { ChildSessionCoordinator.shared.tabForgotten(parent.id) }
        let server = try #require(session.mcpServer)

        let reply = await server.handle(.object([
            "jsonrpc": .string("2.0"), "id": .number(1), "method": .string("tools/call"),
            "params": .object(["name": .string("start_session"), "arguments": .object([
                "initiation": .string("offer"), "title": .string("Fix login"), "prompt": .string("Fix it")
            ])])
        ]))

        #expect(reply?["result"]?["isError"] == .bool(true))
        let text = reply?["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue ?? ""
        #expect(text.contains("no tool use id"))
        #expect(!board.offers.values.contains { $0.parentTabID == parent.id })
    }

    @Test func planModeRefusesAnOffer() throws {
        let task = TaskStore.createTask(in: context, title: "Task", siblings: [])
        let parent = try #require(task.tabs.first)
        parent.permissionMode = .plan
        let id = "toolu_\(UUID().uuidString)"
        defer { ChildSessionCoordinator.shared.tabForgotten(parent.id) }

        #expect(ChildSessionCoordinator.shared.raiseOffer(request(), from: parent, toolUseID: id) == .parentInPlanMode)
        #expect(board.offer(id) == nil)
    }
}
