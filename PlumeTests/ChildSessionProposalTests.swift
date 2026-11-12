import Foundation
import SwiftData
import Testing
@testable import Plume

/// A proposal is a card the parent's agent records with `own_initiative`:
/// it lasts 7 days, can be dismissed, and starts only once, by id, with the
/// settings it was proposed with. The store survives a JSON round trip, and
/// the text around it matches Desktop's.
struct ChildSessionProposalStoreTests {
    private static let created = Date(timeIntervalSince1970: 1_800_000_000)
    private static let day: TimeInterval = 24 * 60 * 60

    private func request(_ extra: [String: JSONValue] = [:]) throws -> StartSessionRequest {
        try StartSessionRequest.parse(
            ["title": .string("Fix login"), "prompt": .string("Fix the login race"), "initiation": .string("own_initiative")]
                .merging(extra) { _, new in new }
        ).get()
    }

    private func store(with id: String = "task_0000abcd", _ extra: [String: JSONValue] = [:]) throws -> ChildSessionProposalStore {
        var store = ChildSessionProposalStore()
        store.add(ChildSessionProposal(id: id, request: try request(extra), createdAt: Self.created))
        return store
    }

    @Test func anIDIsTaskAndEightHexDigits() {
        #expect(ChildSessionProposalStore.makeID(random: 0xAB) == "task_000000ab")
        #expect(ChildSessionProposalStore.makeID().wholeMatch(of: /task_[0-9a-f]{8}/) != nil)
    }

    @Test func aProposalExpiresAfterSevenDays() throws {
        let store = try store()
        let proposal = try #require(store.proposal(id: "task_0000abcd"))
        #expect(!proposal.isExpired(at: Self.created.addingTimeInterval(7 * Self.day - 1)))
        #expect(proposal.isExpired(at: Self.created.addingTimeInterval(7 * Self.day)))
        #expect(store.cardState(id: "task_0000abcd", now: Self.created.addingTimeInterval(7 * Self.day)) == .expired)
    }

    @Test func pruningKeepsTheNewestSettledProposalsAndEveryPendingOne() throws {
        let limit = ChildSessionProposalStore.settledLimit
        var store = ChildSessionProposalStore()
        // An expired proposal settles at its expiry, older than every start below.
        store.add(ChildSessionProposal(id: "expired", request: try request(), createdAt: Self.created.addingTimeInterval(-8 * Self.day)))
        for index in 0..<limit {
            let id = "started-\(index)"
            store.add(ChildSessionProposal(id: id, request: try request(), createdAt: Self.created))
            store.markStarted(id: id, sessionID: "S", name: "n", now: Self.created.addingTimeInterval(Double(index)))
        }
        store.add(ChildSessionProposal(id: "pending", request: try request(), createdAt: Self.created))
        let now = Self.created.addingTimeInterval(400 * Self.day)

        store.prune(now: Self.created.addingTimeInterval(Self.day))
        #expect(store.proposal(id: "expired") == nil)
        #expect(store.proposals.count == limit + 1)

        store.add(ChildSessionProposal(id: "late", request: try request(), createdAt: now))
        _ = store.dismiss(id: "late", reason: nil, byUser: true, now: now)
        store.prune(now: now)
        // "pending" has expired too, but a week after created, later than every start.
        #expect(store.proposal(id: "started-0") == nil)
        #expect(store.proposal(id: "started-1") == nil)
        #expect(store.proposal(id: "started-2") != nil)
        #expect(store.proposal(id: "pending") != nil)
        #expect(store.proposal(id: "late") != nil)
        #expect(store.proposals.count == limit)
    }

    @Test func pruningNeverDropsAProposalThatCanStart() throws {
        var store = ChildSessionProposalStore()
        for index in 0...ChildSessionProposalStore.settledLimit {
            store.add(ChildSessionProposal(id: "p\(index)", request: try request(), createdAt: Self.created))
        }
        store.prune(now: Self.created.addingTimeInterval(Self.day))
        #expect(store.proposals.count == ChildSessionProposalStore.settledLimit + 1)
    }

    @Test func aProposalTheStoreDoesNotHoldWasMadeElsewhere() throws {
        #expect(try store().cardState(id: "task_ffffffff", now: Self.created) == .elsewhere)
    }

    @Test func aStartIsRecordedPastTheLifetimeAndCanBeUndone() throws {
        var store = try store()
        let late = Self.created.addingTimeInterval(8 * Self.day)
        let recorded = store.markStarted(id: "task_0000abcd", sessionID: "CHILD", name: "fix-login", now: late)
        let recordedMissing = store.markStarted(id: "task_ffffffff", sessionID: "CHILD", name: "fix-login", now: late)
        #expect(recorded)
        #expect(!recordedMissing)
        #expect(store.cardState(id: "task_0000abcd", now: late) == .started(sessionID: "CHILD", name: "fix-login"))

        store.reopen(id: "task_0000abcd")
        #expect(store.proposal(id: "task_0000abcd")?.status == .pending)
        #expect(store.proposal(id: "task_0000abcd")?.startedSessionID == nil)
    }

    @Test func repeatedLaunchSettingsMustMatchTheProposal() throws {
        let proposal = try #require(try store(with: "task_00000001", ["model": .string("sonnet"), "use_worktree": .bool(true)]).proposals.first)
        #expect(proposal.conflict(with: [:]) == nil)
        #expect(proposal.conflict(with: ["model": .string("sonnet"), "use_worktree": .bool(true), "context": .string("fresh")]) == nil)
        guard case .invalid(let message) = proposal.conflict(with: ["model": .string("opus")]) else {
            Issue.record("a different model should be refused")
            return
        }
        #expect(message.contains("own brief and settings"))
        #expect(proposal.conflict(with: ["use_worktree": .bool(false)]) != nil)
        #expect(proposal.conflict(with: ["effort": .string("not-an-effort")]) != nil)
    }

    @Test func aRepeatedBriefMustMatchTheProposal() throws {
        let proposal = try #require(try store(with: "task_00000001").proposals.first)
        #expect(proposal.conflict(with: ["title": .string("Fix login"), "prompt": .string(" Fix the login race ")]) == nil)
        guard case .invalid(let message) = proposal.conflict(with: ["title": .string("Fix login"), "prompt": .string("Fix the signup race")]) else {
            Issue.record("a different prompt should be refused")
            return
        }
        #expect(message.contains("prompt differs"))
        #expect(message.contains("send_message"))
        #expect(proposal.conflict(with: ["name": .string("other")]) != nil)
    }

    @Test func anEntryThisBuildCannotReadSurvivesAWrite() throws {
        var store = try store(with: "task_00000001")
        let future = #"{"id":"task_00000002","title":"From a newer build","status":"queued","createdAt":"2027-01-01T00:00:00Z"}"#
        let json = "[" + store.json.dropFirst().dropLast() + "," + future + "]"

        var read = ChildSessionProposalStore(json: json)
        #expect(read.proposals.map(\.id) == ["task_00000001"])
        _ = read.dismiss(id: "task_00000001", reason: nil, byUser: true, now: Self.created)
        let written = try #require(try JSONSerialization.jsonObject(with: Data(read.json.utf8)) as? [[String: Any]])
        #expect(written.map { $0["id"] as? String } == ["task_00000001", "task_00000002"])
        #expect(written.last?["status"] as? String == "queued")
        #expect(written.last?["title"] as? String == "From a newer build")

        store = ChildSessionProposalStore(json: "not json")
        #expect(!store.isWritable)
        #expect(store.json == "not json")
    }

    @Test func aDismissedProposalCannotBeDismissedOrStarted() throws {
        var store = try store()
        let now = Self.created.addingTimeInterval(Self.day)
        let dismissed = try store.dismiss(id: "task_0000abcd", reason: "fixed here", byUser: false, now: now).get()
        #expect(dismissed.status == .dismissed)
        #expect(dismissed.dismissReason == "fixed here")
        #expect(store.cardState(id: "task_0000abcd", now: now) == .dismissed)
        #expect(store.dismiss(id: "task_0000abcd", reason: nil, byUser: true, now: now) == .failure(.dismissed("task_0000abcd")))
        #expect(store.pending(id: "task_0000abcd", now: now) == .failure(.dismissed("task_0000abcd")))
    }

    @Test func startingByIDRefusesUnknownExpiredDismissedAndStartedIDs() throws {
        var store = try store(with: "task_00000001")
        store.add(ChildSessionProposal(id: "task_00000002", request: try request(), createdAt: Self.created))
        store.add(ChildSessionProposal(id: "task_00000003", request: try request(), createdAt: Self.created.addingTimeInterval(-8 * Self.day)))
        let now = Self.created.addingTimeInterval(Self.day)
        _ = store.dismiss(id: "task_00000002", reason: nil, byUser: true, now: now)
        store.markStarted(id: "task_00000001", sessionID: "CHILD", name: "fix-login", now: now)

        #expect(store.pending(id: "task_ffffffff", now: now) == .failure(.unknown("task_ffffffff")))
        #expect(store.pending(id: "task_00000003", now: now) == .failure(.expired("task_00000003")))
        #expect(store.pending(id: "task_00000002", now: now) == .failure(.dismissed("task_00000002")))
        #expect(store.pending(id: "task_00000001", now: now) == .failure(.started("task_00000001", sessionID: "CHILD")))
        #expect(store.cardState(id: "task_00000001", now: now) == .started(sessionID: "CHILD", name: "fix-login"))
    }

    @Test func theStoreSurvivesAJSONRoundTrip() throws {
        var store = try store(with: "task_00000001", [
            "name": .string("fix-login"),
            "background": .string(String(repeating: "Context the child needs. ", count: 5)),
            "use_worktree": .bool(true),
            "model": .string("sonnet"),
            "effort": .string("high"),
            "permission_mode": .string("acceptEdits"),
            "wake_when_done": .bool(false)
        ])
        store.markStarted(id: "task_00000001", sessionID: "CHILD", name: "fix-login", now: Self.created.addingTimeInterval(60))

        #expect(ChildSessionProposalStore(json: store.json) == store)
        #expect(ChildSessionProposalStore(json: "").proposals.isEmpty)
        #expect(ChildSessionProposalStore(json: "not json").proposals.isEmpty)
        #expect(ChildSessionProposalStore().json == "")
    }

    @Test func aProposalStartsWithTheSettingsItWasProposedWith() throws {
        let extra: [String: JSONValue] = [
            "name": .string("fix-login"),
            "context": .string("fork"),
            "use_worktree": .bool(false),
            "model": .string("sonnet"),
            "effort": .string("low"),
            "permission_mode": .string("plan"),
            "wake_when_done": .bool(false)
        ]
        let proposed = try request(extra)
        let proposal = ChildSessionProposal(id: "task_00000001", request: proposed, createdAt: Self.created)
        let decoded = try #require(ChildSessionProposalStore(json: ChildSessionProposalStore(proposals: [proposal]).json).proposals.first)

        var expected = proposed
        expected.initiation = .userAsked
        #expect(try decoded.request().get() == expected)
        #expect(try decoded.request(wakeWhenDone: true).get().wakeWhenDone)
    }

    // MARK: - start_session calls

    @Test func aCallIsAStartAProposalOrTheStartOfOne() throws {
        let base: [String: JSONValue] = ["title": .string("T"), "prompt": .string("P")]
        func parse(_ extra: [String: JSONValue]) -> Result<StartSessionCall, ChildSessionError> {
            StartSessionCall.parse(base.merging(extra) { _, new in new })
        }
        guard case .success(.start) = parse(["initiation": .string("user_asked")]),
              case .success(.propose(let proposed)) = parse(["initiation": .string("own_initiative")]),
              case .success(.propose) = parse(["initiation": .string("offer")])
        else {
            Issue.record("expected a start and two proposals")
            return
        }
        #expect(proposed.initiation == .ownInitiative)
        #expect(StartSessionCall.parse(["proposal_id": .string("task_0000abcd")])
            == .success(.startProposal(id: "task_0000abcd", wakeWhenDone: nil, settings: [:])))
        #expect(StartSessionCall.parse(["proposal_id": .string("task_0000abcd"), "wake_when_done": .bool(false)])
            == .success(.startProposal(id: "task_0000abcd", wakeWhenDone: false, settings: [:])))
        guard case .failure(.invalid) = StartSessionCall.parse(["proposal_id": .string("task_0000abcd"), "colour": .string("red")]) else {
            Issue.record("a proposal_id with an unknown argument should be refused")
            return
        }
    }

    @Test func aProposalIDIgnoresInitiationAndPassesOnTheRestToCheck() {
        let call = StartSessionCall.parse([
            "proposal_id": .string("task_0000abcd"),
            "initiation": .string("user_asked"), "title": .string("T"), "prompt": .string("P"),
            "model": .string("sonnet"), "use_worktree": .bool(true)
        ])
        #expect(call == .success(.startProposal(
            id: "task_0000abcd", wakeWhenDone: nil,
            settings: ["title": .string("T"), "prompt": .string("P"), "model": .string("sonnet"), "use_worktree": .bool(true)]
        )))
    }

    @Test func aPaddedInitiationStillReadsAsAProposal() {
        #expect(StartSessionCall.isProposal(["initiation": .string(" own_initiative\n")]))
        #expect(!StartSessionCall.isProposal(["initiation": .string(" user_asked ")]))
    }

    @Test func aNullOrBlankProposalIDIsAbsent() {
        let proposing: [String: JSONValue] = [
            "title": .string("T"), "prompt": .string("P"), "initiation": .string("own_initiative")
        ]
        for blank: JSONValue in [.null, .string(""), .string("  ")] {
            let arguments = proposing.merging(["proposal_id": blank]) { $1 }
            #expect(StartSessionCall.isProposal(arguments))
            guard case .success(.propose) = StartSessionCall.parse(arguments) else {
                Issue.record("a blank proposal_id should leave the call a proposal")
                continue
            }
        }
    }

    // MARK: - Text for the model

    @Test func aProposalsResultMatchesDesktop() {
        #expect(ChildSessionFormats.proposed(title: "Child session proposal card test", taskID: "task_b3337f25")
            == "Proposed \"Child session proposal card test\" (task_id: task_b3337f25). The user sees a card and nothing runs until they start it — with a click, or by telling you (then call start_session with proposal_id task_b3337f25 and nothing else). It expires in 7 days unless started; dismiss_task withdraws it sooner if it goes stale. Don't wait for it and don't repeat the introduction; carry on with what you were doing.")
    }

    @Test func theStartedNoteMatchesDesktopAndRendersAsOneRow() throws {
        let child = ChildSessionFormats.Participant(sessionID: "6F1C", title: "Fix login", name: "fix-login")
        let note = ChildSessionFormats.proposalStartedNote(taskID: "task_b3337f25", title: "Fix <login>", child: child)
        #expect(note.hasPrefix("<system-reminder>\nThe user started your proposal task_b3337f25 (\"Fix &lt;login>\") as session 6F1C. It runs on its own; a note reaches you when it ends a turn.\n</system-reminder>\n<side-sessions-event>"))
        let split = InjectedContent.splittingLeadingSystemReminders(note)
        let footer = try #require(split.reminders.last)
        guard case .sideSessionEvent(let event) = InjectedContent.classify(text: footer, isMeta: false) else {
            Issue.record("expected a side-session event")
            return
        }
        #expect(event.kind == .proposalStarted)
        #expect(event.sessionID == "6F1C")
        #expect(event.summary == "↳ fix-login started from its proposal")
    }

    @Test func aProposingCallIsRecognizedByItsResult() {
        let proposed = ChildSessionFormats.proposed(title: "Fix", taskID: "task_0123abcd")
        func call(_ name: String = "mcp__plume__start_session", result: String?, failed: Bool = false) -> ToolCall {
            ToolCall(
                id: "toolu_1", name: name, summary: ToolCallSummary(name: name),
                input: .json(#"{"title": "Fix", "prompt": "Do it"}"#), result: result, didFail: failed
            )
        }
        #expect(ChildSessionFormats.proposalID(of: call(result: proposed)) == "task_0123abcd")
        #expect(ChildSessionFormats.proposalID(of: call(result: "Started session \"Fix\" (session_id: X, name: fix).")) == nil)
        #expect(ChildSessionFormats.proposalID(of: call(result: proposed, failed: true)) == nil)
        #expect(ChildSessionFormats.proposalID(of: call("mcp__other__start_session", result: proposed)) == nil)
        #expect(ChildSessionFormats.proposalID(of: call(result: nil)) == nil)
        let tricky = ChildSessionFormats.proposed(title: "Redo (task_id: task_00000001) cleanup", taskID: "task_0123abcd")
        #expect(ChildSessionFormats.proposalID(of: call(result: tricky)) == "task_0123abcd")
        let fallback = ChildSessionFormats.proposalFallback(of: call(result: proposed))
        #expect(fallback.title == "Fix")
        #expect(fallback.prompt == "Do it")
    }
}

/// The coordinator keeps a parent's proposals on its tab, so they outlive a
/// relaunch, and answers `start_session` and `dismiss_task` calls about them
/// over the MCP server.
@MainActor
struct ChildSessionProposalCoordinatorTests {
    private let container: ModelContainer
    private let context: ModelContext

    init() throws {
        container = try ModelContainer(
            for: Schema([TaskGroup.self, WorkTask.self, TaskTab.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        context = ModelContext(container)
    }

    private func makeParent() throws -> (WorkTask, TaskTab, HeadlessSession) {
        let task = TaskStore.createTask(in: context, title: "Task", siblings: [])
        let parent = try #require(task.tabs.first)
        let session = HeadlessSession(tabID: parent.id, taskID: task.id)
        ChildSessionCoordinator.shared.attach(to: session, task: task, tab: parent)
        return (task, parent, session)
    }

    private func call(_ session: HeadlessSession, _ tool: String, _ arguments: [String: JSONValue]) async throws -> (text: String, isError: Bool) {
        let server = try #require(session.mcpServer)
        let reply = await server.handle(.object([
            "jsonrpc": .string("2.0"), "id": .number(1), "method": .string("tools/call"),
            "params": .object(["name": .string(tool), "arguments": .object(arguments)])
        ]))
        let result = try #require(reply?["result"])
        return (result["content"]?.arrayValue?.first?["text"]?.stringValue ?? "", result["isError"] == .bool(true))
    }

    private static let proposal: [String: JSONValue] = [
        "initiation": .string("own_initiative"), "title": .string("Fix login"), "prompt": .string("Fix the login race")
    ]

    @Test func anOwnInitiativeCallRecordsAProposalThatSurvivesARelaunch() async throws {
        let (_, parent, session) = try makeParent()
        defer { ChildSessionCoordinator.shared.tabForgotten(parent.id) }

        let reply = try await call(session, "start_session", Self.proposal)

        #expect(!reply.isError)
        #expect(reply.text.hasPrefix("Proposed \"Fix login\" (task_id: task_"))
        let taskID = try #require(ChildSessionFormats.proposalID(of: ToolCall(
            id: "t", name: PlumeMCPTool.startSession.qualifiedName, summary: ToolCallSummary(name: "start_session"),
            input: .json("{}"), result: reply.text
        )))
        #expect(parent.task?.tabs.count == 1)

        try context.save()
        let parentID = parent.id
        let reloaded = try #require(try ModelContext(container).fetch(FetchDescriptor<TaskTab>(predicate: #Predicate { $0.id == parentID })).first)
        let stored = try #require(ChildSessionProposalStore(json: reloaded.childProposalsJSON).proposal(id: taskID))
        #expect(stored.title == "Fix login")
        #expect(stored.prompt == "Fix the login race")
        #expect(stored.status == .pending)
    }

    @Test func dismissTaskWithdrawsAPendingProposal() async throws {
        let (_, parent, session) = try makeParent()
        defer { ChildSessionCoordinator.shared.tabForgotten(parent.id) }
        let request = try StartSessionRequest.parse(Self.proposal).get()
        _ = ChildSessionCoordinator.shared.propose(request, from: parent)
        let taskID = try #require(ChildSessionProposalStore(json: parent.childProposalsJSON).proposals.first?.id)

        let reply = try await call(session, "dismiss_task", ["task_id": .string(taskID), "reason": .string("fixed in this session")])

        #expect(!reply.isError)
        #expect(reply.text == "Dismissed \"Fix login\" (task_id: \(taskID)). Its card now reads as dismissed, and it can no longer be started.")
        let stored = try #require(ChildSessionProposalStore(json: parent.childProposalsJSON).proposal(id: taskID))
        #expect(stored.status == .dismissed)
        #expect(stored.dismissReason == "fixed in this session")
        #expect(stored.dismissedByUser == false)

        let again = try await call(session, "dismiss_task", ["task_id": .string(taskID)])
        #expect(again.isError)
        #expect(try await call(session, "dismiss_task", [:]).isError)
    }

    @Test func aProposalIDThatCannotStartIsAToolError() async throws {
        let (_, parent, session) = try makeParent()
        defer { ChildSessionCoordinator.shared.tabForgotten(parent.id) }
        let request = try StartSessionRequest.parse(Self.proposal).get()
        let now = Date.now
        ChildSessionCoordinator.shared.withProposals(of: parent, now: now) { store in
            store.add(ChildSessionProposal(id: "task_00000001", request: request, createdAt: now.addingTimeInterval(-8 * 24 * 60 * 60)))
            store.add(ChildSessionProposal(id: "task_00000002", request: request, createdAt: now))
            store.add(ChildSessionProposal(id: "task_00000003", request: request, createdAt: now))
            _ = store.dismiss(id: "task_00000002", reason: nil, byUser: true, now: now)
            store.markStarted(id: "task_00000003", sessionID: "CHILD", name: "fix-login", now: now)
        }

        let unknown = try await call(session, "start_session", ["proposal_id": .string("task_ffffffff")])
        #expect(unknown.isError)
        #expect(unknown.text == ChildSessionProposalError.unknown("task_ffffffff").message)
        #expect(try await call(session, "start_session", ["proposal_id": .string("task_00000001")]).text
            == ChildSessionProposalError.expired("task_00000001").message)
        #expect(try await call(session, "start_session", ["proposal_id": .string("task_00000002")]).text
            == ChildSessionProposalError.dismissed("task_00000002").message)
        #expect(try await call(session, "start_session", ["proposal_id": .string("task_00000003")]).text
            == ChildSessionProposalError.started("task_00000003", sessionID: "CHILD").message)
        #expect(parent.task?.tabs.count == 1)
    }

    @Test func aStartFromTheCardAfterExpirySaysItExpired() async throws {
        let (_, parent, _) = try makeParent()
        defer { ChildSessionCoordinator.shared.tabForgotten(parent.id) }
        let request = try StartSessionRequest.parse(Self.proposal).get()
        let created = Date.now
        _ = ChildSessionCoordinator.shared.withProposals(of: parent, now: created) { store in
            store.add(ChildSessionProposal(id: "task_00000001", request: request, createdAt: created))
        }

        let later = created.addingTimeInterval(7 * 24 * 60 * 60 + 1)
        let result = await ChildSessionCoordinator.shared.startProposal("task_00000001", from: parent, byUser: true, now: later)

        #expect(result == .failure(.proposal(.expired("task_00000001"))))
        let store = ChildSessionProposalStore(json: parent.childProposalsJSON)
        #expect(store.cardState(id: "task_00000001", now: later) == .expired)
        #expect(ChildSessionProposalActivity.shared.failure(of: "task_00000001", in: parent.id, showing: .expired)?.contains("expired") == true)
    }

    @Test func aConflictingLaunchSettingIsRefusedAndARedundantBriefIgnored() async throws {
        let (_, parent, session) = try makeParent()
        defer { ChildSessionCoordinator.shared.tabForgotten(parent.id) }
        parent.permissionMode = .plan
        let request = try StartSessionRequest.parse(Self.proposal.merging(["model": .string("sonnet")]) { $1 }).get()
        let taskID = try ChildSessionCoordinator.shared.propose(request, from: parent).get().id
        #expect(ChildSessionProposalStore(json: parent.childProposalsJSON).proposals.map(\.id) == [taskID])

        let conflicting = try await call(session, "start_session", ["proposal_id": .string(taskID), "model": .string("opus")])
        #expect(conflicting.isError)
        #expect(conflicting.text.contains("own brief and settings"))

        // Past parsing and the settings check, the start meets plan mode.
        let redundant = try await call(session, "start_session", [
            "proposal_id": .string(taskID), "title": .string("Fix login"), "initiation": .string("user_asked"),
            "model": .string("sonnet")
        ])
        #expect(redundant.text == ChildSessionError.parentInPlanMode.message)
    }

    @Test func aFailureClearsOnDismissalAndWhenTheTabIsForgotten() async throws {
        let (_, parent, _) = try makeParent()
        defer { ChildSessionCoordinator.shared.tabForgotten(parent.id) }
        parent.permissionMode = .plan
        let request = try StartSessionRequest.parse(Self.proposal).get()
        let first = try ChildSessionCoordinator.shared.propose(request, from: parent).get().id
        let second = try ChildSessionCoordinator.shared.propose(request, from: parent).get().id
        let activity = ChildSessionProposalActivity.shared
        _ = await ChildSessionCoordinator.shared.startProposal(first, from: parent, byUser: true)
        _ = await ChildSessionCoordinator.shared.startProposal(second, from: parent, byUser: true)
        #expect(activity.failure(of: first, in: parent.id, showing: .pending) != nil)

        _ = ChildSessionCoordinator.shared.dismissProposal(first, reason: nil, from: parent, byUser: true)
        #expect(activity.failure(of: first, in: parent.id, showing: .pending) == nil)
        #expect(activity.failure(of: second, in: parent.id, showing: .pending) != nil)

        ChildSessionCoordinator.shared.tabForgotten(parent.id)
        #expect(activity.failure(of: second, in: parent.id, showing: .pending) == nil)
    }

    @Test func aFailureShowsOnlyWhileTheCardReadsAsItDidThen() {
        let activity = ChildSessionProposalActivity.shared
        let tabID = UUID()
        defer { activity.forget(tabID) }
        activity.fail("task_00000001", in: tabID, .init(text: "plan mode", state: .pending))
        #expect(activity.failure(of: "task_00000001", in: tabID, showing: .pending) == "plan mode")
        #expect(activity.failure(of: "task_00000001", in: tabID, showing: .expired) == nil)
    }

    @Test func aChildsCardsBelongToItsParentWhileItIsOpen() throws {
        let (task, parent, _) = try makeParent()
        defer { ChildSessionCoordinator.shared.tabForgotten(parent.id) }
        let child = TaskStore.addChildTab(to: task, parent: parent, in: context)

        #expect(ChildSessionCoordinator.proposalOwner(of: parent) === parent)
        #expect(ChildSessionCoordinator.proposalOwner(of: child) === parent)

        TaskStore.closeTab(parent, in: context)
        #expect(ChildSessionCoordinator.proposalOwner(of: child) == nil)
    }

    @Test func aParentInPlanModeCannotStartItsProposalAndTheCardSaysWhy() async throws {
        let (_, parent, _) = try makeParent()
        defer { ChildSessionCoordinator.shared.tabForgotten(parent.id) }
        parent.permissionMode = .plan
        let request = try StartSessionRequest.parse(Self.proposal).get()
        _ = ChildSessionCoordinator.shared.propose(request, from: parent)
        let taskID = try #require(ChildSessionProposalStore(json: parent.childProposalsJSON).proposals.first?.id)

        let result = await ChildSessionCoordinator.shared.startProposal(taskID, from: parent, byUser: true)

        #expect(result == .failure(.parentInPlanMode))
        #expect(ChildSessionProposalStore(json: parent.childProposalsJSON).proposal(id: taskID)?.status == .pending)
        #expect(ChildSessionProposalActivity.shared.failure(of: taskID, in: parent.id, showing: .pending) == ChildSessionError.parentInPlanMode.message)
        #expect(!ChildSessionProposalActivity.shared.isStarting(taskID, in: parent.id))
        #expect(parent.task?.tabs.count == 1)
    }
}
