import Testing
import Foundation
@testable import Plume

/// Claude Code moves a live transcript between project directories on
/// `EnterWorktree`/`ExitWorktree`: it renames `<dir>/<session>.jsonl` and moves
/// `<dir>/<session>/subagents/` separately, sometimes twice within a
/// millisecond. These cover what the store publishes across such a move.
@MainActor
struct TranscriptRelocationTests {
    enum Sequence: String, CaseIterable, CustomTestStringConvertible {
        /// A → B → C, `subagents/` and the send all land before the store
        /// reads again, so it sees only where the session ended up.
        case moveAndSendBeforeAnyRead
        /// A → B, a debounced read runs, then B → C and the send.
        case readBetweenRenames
        /// A parse of A is still running when the file moves, so the read the
        /// rename schedules finds the tab in flight.
        case renameDuringInFlightRead
        /// A → B leaves an empty file at A, then B → C and the send.
        case renameLeavingAnEmptyStub

        var testDescription: String { rawValue }
    }

    @Test(arguments: Sequence.allCases)
    func messagesMatchTheRelocatedFileAfterAMove(_ sequence: Sequence) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = TranscriptStore(debounce: .milliseconds(10), projectsDirectory: fixture.root)
        defer { store.stopAll() }
        let recorder = ReadRecorder(store: store, tab: fixture.tab)

        store.watch(tabID: fixture.tab, transcriptPath: fixture.pathA)
        #expect(await recorder.wait { store.transcript(forTab: fixture.tab)?.messages.isEmpty == false })

        switch sequence {
        case .moveAndSendBeforeAnyRead:
            try fixture.renameAToB()
            try fixture.renameBToC()
            try fixture.moveSubagents(from: fixture.dirA, to: fixture.dirC)
            fixture.appendSend(to: fixture.pathC)
        case .readBetweenRenames:
            try fixture.renameAToB()
            #expect(await recorder.wait { recorder.hasRead(fixture.pathB) })
            try fixture.renameBToC()
            try fixture.moveSubagents(from: fixture.dirA, to: fixture.dirC)
            fixture.appendSend(to: fixture.pathC)
        case .renameDuringInFlightRead:
            recorder.holdNextRead(of: fixture.pathA)
            fixture.append(Fixture.userLine("Kick off a read"), to: fixture.pathA)
            await recorder.waitUntilHeld()
            try fixture.renameAToB()
            try fixture.renameBToC()
            try fixture.moveSubagents(from: fixture.dirA, to: fixture.dirC)
            fixture.appendSend(to: fixture.pathC)
            #expect(await recorder.wait { recorder.deferredReads > 0 })
            recorder.releaseHeld()
        case .renameLeavingAnEmptyStub:
            try fixture.renameAToB()
            FileManager.default.createFile(atPath: fixture.pathA, contents: nil)
            try fixture.renameBToC()
            try fixture.moveSubagents(from: fixture.dirA, to: fixture.dirC)
            fixture.appendSend(to: fixture.pathC)
        }

        let expected = TranscriptParser.parse(try Data(contentsOf: URL(fileURLWithPath: fixture.pathC)))
        let settled = await recorder.wait(timeout: .seconds(5)) {
            store.transcript(forTab: fixture.tab) == expected
        }
        let published = store.transcript(forTab: fixture.tab)
        #expect(
            settled,
            """
            published \(published?.messages.count ?? -1) messages, C holds \(expected.messages.count); \
            watching \(store.watchedPath(forTab: fixture.tab).map(fixture.name) ?? "nothing"); \
            \(recorder.reads.count) reads: \(recorder.reads.map { fixture.name($0.path ?? "nil") + ":" + String($0.messageCount ?? -1) })
            """
        )
    }

    @Test(arguments: [Sequence.moveAndSendBeforeAnyRead, .readBetweenRenames, .renameLeavingAnEmptyStub])
    func aMoveNeverEmptiesOrShrinksTheTranscript(_ sequence: Sequence) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = TranscriptStore(debounce: .milliseconds(10), projectsDirectory: fixture.root)
        defer { store.stopAll() }
        let recorder = ReadRecorder(store: store, tab: fixture.tab)

        store.watch(tabID: fixture.tab, transcriptPath: fixture.pathA)
        #expect(await recorder.wait { store.transcript(forTab: fixture.tab)?.messages.isEmpty == false })
        let firstRead = recorder.reads.count - 1

        try fixture.renameAToB()
        if sequence == .readBetweenRenames {
            #expect(await recorder.wait { recorder.hasRead(fixture.pathB) })
        }
        if sequence == .renameLeavingAnEmptyStub {
            FileManager.default.createFile(atPath: fixture.pathA, contents: nil)
            #expect(await recorder.wait { recorder.hasRead(fixture.pathA, after: firstRead + 1) })
        }
        try fixture.renameBToC()
        try fixture.moveSubagents(from: fixture.dirA, to: fixture.dirC)
        fixture.appendSend(to: fixture.pathC)
        let expected = TranscriptParser.parse(try Data(contentsOf: URL(fileURLWithPath: fixture.pathC)))
        #expect(await recorder.wait(timeout: .seconds(5)) { store.transcript(forTab: fixture.tab) == expected })

        let counts = recorder.reads[firstRead...].map(\.messageCount)
        #expect(!counts.contains(nil), "a read left the tab with no transcript: \(counts)")
        let shrank = zip(counts, counts.dropFirst()).contains { ($1 ?? 0) < ($0 ?? 0) }
        #expect(!shrank, "message counts across the move: \(counts)")
    }

    /// A remount, a relaunch or an unarchive re-watches the path the tab
    /// persisted, which can be the one the session moved away from.
    @Test func reWatchingTheOldPathKeepsTheRelocatedWatch() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let tracker = SubagentCompletionTracker()
        let store = TranscriptStore(
            debounce: .milliseconds(10), completionTracker: tracker, projectsDirectory: fixture.root
        )
        defer { store.stopAll() }
        let recorder = ReadRecorder(store: store, tab: fixture.tab)

        store.watch(tabID: fixture.tab, transcriptPath: fixture.pathA)
        #expect(await recorder.wait { store.subagents(forTab: fixture.tab).first?.status == .done })
        try fixture.renameAToB()
        try fixture.renameBToC()
        try fixture.moveSubagents(from: fixture.dirA, to: fixture.dirC)
        #expect(await recorder.wait { recorder.hasRead(fixture.pathC) })
        let transcript = store.transcript(forTab: fixture.tab)
        let subagents = store.subagents(forTab: fixture.tab)
        let readsBefore = recorder.reads.count

        store.watch(tabID: fixture.tab, transcriptPath: fixture.pathA)

        #expect(store.watchedPath(forTab: fixture.tab) == fixture.pathC)
        #expect(store.transcript(forTab: fixture.tab) == transcript)
        #expect(store.subagents(forTab: fixture.tab) == subagents)
        let subagent = try #require(subagents.first)
        #expect(tracker.hasSettled(subagent, tabID: fixture.tab))

        fixture.appendSend(to: fixture.pathC)
        #expect(await recorder.wait {
            store.transcript(forTab: fixture.tab)?.messages.count == fixture.expectedMessageCount
        })
        let later = recorder.reads[readsBefore...]
        #expect(later.allSatisfy { ($0.messageCount ?? 0) >= (transcript?.messages.count ?? 0) })
        #expect(later.allSatisfy { !$0.subagents.isEmpty })
    }

    /// The terminal transport's hooks report the moved path, often before
    /// the store has noticed the move itself.
    @Test func aHookReportingTheMovedPathKeepsTheTab() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let tracker = SubagentCompletionTracker()
        let store = TranscriptStore(
            debounce: .milliseconds(10), completionTracker: tracker, projectsDirectory: fixture.root
        )
        defer { store.stopAll() }
        let recorder = ReadRecorder(store: store, tab: fixture.tab)

        store.watch(tabID: fixture.tab, transcriptPath: fixture.pathA)
        #expect(await recorder.wait { store.subagents(forTab: fixture.tab).first?.status == .done })
        let transcript = store.transcript(forTab: fixture.tab)
        let subagents = store.subagents(forTab: fixture.tab)
        let readsBefore = recorder.reads.count

        try fixture.renameAToB()
        try fixture.renameBToC()
        try fixture.moveSubagents(from: fixture.dirA, to: fixture.dirC)
        store.watch(tabID: fixture.tab, transcriptPath: fixture.pathC)

        #expect(recorder.reads.count == readsBefore)
        #expect(store.watchedPath(forTab: fixture.tab) == fixture.pathC)
        #expect(store.transcript(forTab: fixture.tab) == transcript)
        #expect(store.subagents(forTab: fixture.tab) == subagents)

        #expect(await recorder.wait { recorder.hasRead(fixture.pathC) })
        let subagent = try #require(store.subagents(forTab: fixture.tab).first)
        #expect(tracker.hasSettled(subagent, tabID: fixture.tab))
        #expect(tracker.completionInstant(forSubagentID: Fixture.subagentID, tabID: fixture.tab) == nil)
    }

    /// `/clear` starts a new session file, which shares nothing with the old
    /// one even after the old one has moved.
    @Test func aDifferentSessionFileStillTearsDownAfterAMove() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let tracker = SubagentCompletionTracker()
        let store = TranscriptStore(
            debounce: .milliseconds(10), completionTracker: tracker, projectsDirectory: fixture.root
        )
        defer { store.stopAll() }
        let recorder = ReadRecorder(store: store, tab: fixture.tab)

        store.watch(tabID: fixture.tab, transcriptPath: fixture.pathA)
        #expect(await recorder.wait { store.subagents(forTab: fixture.tab).first?.status == .done })
        try fixture.renameAToB()
        try fixture.renameBToC()
        try fixture.moveSubagents(from: fixture.dirA, to: fixture.dirC)
        #expect(await recorder.wait { recorder.hasRead(fixture.pathC) })
        let subagent = try #require(store.subagents(forTab: fixture.tab).first)

        let newSession = fixture.dirC.appending(path: "\(UUID().uuidString).jsonl").path
        try Data(Fixture.userLine("A fresh start").utf8).write(to: URL(fileURLWithPath: newSession))
        store.watch(tabID: fixture.tab, transcriptPath: newSession)

        #expect(store.watchedPath(forTab: fixture.tab) == newSession)
        #expect(store.transcript(forTab: fixture.tab) == nil)
        #expect(store.subagents(forTab: fixture.tab).isEmpty)
        #expect(!tracker.hasSettled(subagent, tabID: fixture.tab))
    }

    enum SubagentMove: String, CaseIterable, CustomTestStringConvertible {
        case immediatelyAfterTheFile
        /// A read at C runs before `subagents/` arrives.
        case afterAReadAtTheNewPath
        /// `subagents/` moves to C, a read at A runs, then the file follows.
        case subagentsFirst

        var testDescription: String { rawValue }
    }

    private func move(_ move: SubagentMove, _ fixture: Fixture, _ recorder: ReadRecorder) async throws {
        switch move {
        case .immediatelyAfterTheFile:
            try fixture.renameAToB()
            try fixture.renameBToC()
            try fixture.moveSubagents(from: fixture.dirA, to: fixture.dirC)
        case .afterAReadAtTheNewPath:
            try fixture.renameAToB()
            try fixture.renameBToC()
            #expect(await recorder.wait { recorder.hasRead(fixture.pathC) })
            try fixture.moveSubagents(from: fixture.dirA, to: fixture.dirC)
        case .subagentsFirst:
            try fixture.moveSubagents(from: fixture.dirA, to: fixture.dirC)
            let readsBefore = recorder.reads.count
            fixture.append(Fixture.userLine("Written mid-move"), to: fixture.pathA)
            #expect(await recorder.wait { recorder.hasRead(fixture.pathA, after: readsBefore) })
            try fixture.renameAToB()
            try fixture.renameBToC()
        }
        fixture.appendSend(to: fixture.pathC)
    }

    @Test(arguments: SubagentMove.allCases)
    func aFinishedSubagentNeverReadsAsNotStarted(_ move: SubagentMove) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = TranscriptStore(debounce: .milliseconds(10), projectsDirectory: fixture.root)
        defer { store.stopAll() }
        let recorder = ReadRecorder(store: store, tab: fixture.tab)

        store.watch(tabID: fixture.tab, transcriptPath: fixture.pathA)
        #expect(await recorder.wait { store.subagents(forTab: fixture.tab).first?.status == .done })
        let firstRead = recorder.reads.count - 1

        try await self.move(move, fixture, recorder)
        #expect(await recorder.wait(timeout: .seconds(5)) {
            store.subagents(forTab: fixture.tab).first?.status == .done
                && store.transcript(forTab: fixture.tab)?.messages.count == fixture.expectedMessageCount
        })

        #expect(store.subagents(forTab: fixture.tab).map(\.id) == [Fixture.subagentID])
        let statuses = recorder.reads[firstRead...].map { $0.subagents.first { $0.id == Fixture.subagentID }?.status }
        #expect(!statuses.contains(.notStarted), "subagent status per read: \(statuses)")
        #expect(!statuses.contains(nil), "subagent status per read: \(statuses)")
    }

    /// The reported symptom: a subagent that had already finished before the
    /// move reappears among the live rows afterwards.
    @Test(arguments: SubagentMove.allCases)
    func aSubagentFinishedBeforeTheMoveStaysSettled(_ move: SubagentMove) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let tracker = SubagentCompletionTracker()
        let store = TranscriptStore(
            debounce: .milliseconds(10), completionTracker: tracker, projectsDirectory: fixture.root
        )
        defer { store.stopAll() }
        let recorder = ReadRecorder(store: store, tab: fixture.tab)

        store.watch(tabID: fixture.tab, transcriptPath: fixture.pathA)
        #expect(await recorder.wait { store.subagents(forTab: fixture.tab).first?.status == .done })
        let before = try #require(store.subagents(forTab: fixture.tab).first)
        #expect(tracker.hasSettled(before, tabID: fixture.tab))

        try await self.move(move, fixture, recorder)
        #expect(await recorder.wait(timeout: .seconds(5)) {
            store.subagents(forTab: fixture.tab).first?.status == .done
                && store.transcript(forTab: fixture.tab)?.messages.count == fixture.expectedMessageCount
        })

        let after = try #require(store.subagents(forTab: fixture.tab).first)
        let counts = recorder.reads.map(\.subagents.count)
        #expect(tracker.hasSettled(after, tabID: fixture.tab), "subagent count per read: \(counts)")
        #expect(tracker.completionInstant(forSubagentID: Fixture.subagentID, tabID: fixture.tab) == nil)
    }

    /// Nothing writes the transcript after `subagents/` lands, so only a watch
    /// on the directory's arrival can bring the store a read that sees it.
    @Test func subagentsSurviveTheirDirectoryArrivingLate() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = TranscriptStore(debounce: .milliseconds(10), projectsDirectory: fixture.root)
        defer { store.stopAll() }
        let recorder = ReadRecorder(store: store, tab: fixture.tab)

        store.watch(tabID: fixture.tab, transcriptPath: fixture.pathA)
        #expect(await recorder.wait { store.subagents(forTab: fixture.tab).first?.status == .done })
        let firstRead = recorder.reads.count - 1

        try fixture.renameAToB()
        try fixture.renameBToC()
        #expect(await recorder.wait { recorder.hasRead(fixture.pathC) })
        let readsBeforeArrival = recorder.reads.count
        try fixture.moveSubagents(from: fixture.dirA, to: fixture.dirC)
        #expect(await recorder.wait { recorder.hasRead(fixture.pathC, after: readsBeforeArrival) })

        let counts = recorder.reads[firstRead...].map(\.subagents.count)
        #expect(!counts.contains(0), "subagent count per read: \(counts)")
        #expect(store.subagents(forTab: fixture.tab).map(\.id) == [Fixture.subagentID])
        #expect(store.subagents(forTab: fixture.tab).first?.status == .done)
    }

    /// A directory that never arrives must not pin carried rows, or the
    /// task's working status, forever.
    @Test func carriedSubagentsExpireWhenTheirDirectoryNeverArrives() async throws {
        let fixture = try Fixture(parentReportsCompletion: false)
        defer { fixture.remove() }
        let store = TranscriptStore(
            debounce: .milliseconds(10),
            projectsDirectory: fixture.root,
            carriedSubagentExpiry: .milliseconds(100)
        )
        defer { store.stopAll() }
        let recorder = ReadRecorder(store: store, tab: fixture.tab)

        store.watch(tabID: fixture.tab, transcriptPath: fixture.pathA)
        #expect(await recorder.wait { store.subagents(forTab: fixture.tab).count == 1 })
        try fixture.renameAToB()
        try fixture.renameBToC()
        #expect(await recorder.wait { recorder.hasRead(fixture.pathC) })

        #expect(await recorder.wait { store.subagents(forTab: fixture.tab).isEmpty })
    }

    /// One unreadable subagent file must not freeze the rest of the list.
    @Test func anUnreadableSubagentFileStillLetsOthersUpdate() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = TranscriptStore(debounce: .milliseconds(10), projectsDirectory: fixture.root)
        defer { store.stopAll() }
        let recorder = ReadRecorder(store: store, tab: fixture.tab)

        store.watch(tabID: fixture.tab, transcriptPath: fixture.pathA)
        #expect(await recorder.wait { store.subagents(forTab: fixture.tab).count == 1 })

        let subagents = fixture.dirA.appending(path: "\(fixture.session)/subagents")
        let unreadable = subagents.appending(path: "agent-\(Fixture.subagentID).jsonl").path
        let line = #"{"type":"assistant","uuid":"f1","isSidechain":true,"message":{"role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"done"}]}}"#
        try Data((line + "\n").utf8).write(to: subagents.appending(path: "agent-fresh.jsonl"))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadable)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: unreadable) }

        fixture.append(Fixture.userLine("Trigger a read"), to: fixture.pathA)
        #expect(await recorder.wait { store.subagents(forTab: fixture.tab).count == 2 })
        #expect(Set(store.subagents(forTab: fixture.tab).map(\.id)) == [Fixture.subagentID, "fresh"])
    }

    /// Carried rows are still corrected for liveness, so a subagent left
    /// working when its process died cannot pin the task at working.
    @Test func aCarriedWorkingSubagentSettlesWhenItsProcessDies() async throws {
        let fixture = try Fixture(parentReportsCompletion: false)
        defer { fixture.remove() }
        let liveness = Liveness()
        let store = TranscriptStore(
            debounce: .milliseconds(10),
            projectsDirectory: fixture.root,
            isTabLive: { _ in liveness.isLive }
        )
        defer { store.stopAll() }
        let recorder = ReadRecorder(store: store, tab: fixture.tab)

        store.watch(tabID: fixture.tab, transcriptPath: fixture.pathA)
        #expect(await recorder.wait { store.subagents(forTab: fixture.tab).first?.status == .working })
        try fixture.renameAToB()
        try fixture.renameBToC()
        #expect(await recorder.wait { recorder.hasRead(fixture.pathC) })
        #expect(store.subagents(forTab: fixture.tab).first?.status == .working)

        liveness.isLive = false
        let readsBefore = recorder.reads.count
        fixture.appendSend(to: fixture.pathC)
        #expect(await recorder.wait { recorder.hasRead(fixture.pathC, after: readsBefore) })

        #expect(store.subagents(forTab: fixture.tab).map(\.id) == [Fixture.subagentID])
        #expect(store.subagents(forTab: fixture.tab).first?.status == .interrupted)
    }
}

@MainActor
private final class Liveness {
    var isLive = true
}

/// Records what the store published after every read of one tab, and lets a
/// test wait on that signal with a ceiling for the case where reads stop.
@MainActor
private final class ReadRecorder {
    struct Read {
        let path: String?
        /// The file this read parsed. A read that re-points reports the new
        /// `path` but loaded the old file.
        let loadedPath: String?
        let messageCount: Int?
        let subagents: [SubagentTranscript]
    }

    private(set) var reads: [Read] = []
    private(set) var deferredReads = 0
    private var waiter: (condition: () -> Bool, resume: (Bool) -> Void)?
    /// One read per tab at a time, so the latest load belongs to the read
    /// that publishes next.
    private var lastLoaded: String?
    private var holdPath: String?
    private var held: CheckedContinuation<Void, Never>?
    private var onHeld: CheckedContinuation<Void, Never>?

    init(store: TranscriptStore, tab: UUID) {
        store.afterLoadingTranscript = { [weak self] path in await self?.loaded(path) }
        store.didDeferRead = { [weak self] tabID in
            guard let self, tabID == tab else { return }
            deferredReads += 1
            if let waiter, waiter.condition() { waiter.resume(true) }
        }
        store.didRead = { [weak self, weak store] tabID in
            guard let self, let store, tabID == tab else { return }
            reads.append(Read(
                path: store.watchedPath(forTab: tab),
                loadedPath: lastLoaded,
                messageCount: store.transcript(forTab: tab)?.messages.count,
                subagents: store.subagents(forTab: tab)
            ))
            if let waiter, waiter.condition() { waiter.resume(true) }
        }
    }

    /// Whether a read that loaded `path` has published, counting only reads
    /// from index `after` on.
    func hasRead(_ path: String, after index: Int = 0) -> Bool {
        reads[min(index, reads.count)...].contains { $0.loadedPath == path && $0.messageCount != nil }
    }

    /// Suspends the next read of `path` after it has loaded its bytes, until
    /// `releaseHeld`.
    func holdNextRead(of path: String) {
        holdPath = path
    }

    func waitUntilHeld() async {
        guard held == nil else { return }
        await withCheckedContinuation { onHeld = $0 }
    }

    func releaseHeld() {
        held?.resume()
        held = nil
    }

    private func loaded(_ path: String) async {
        lastLoaded = path
        guard path == holdPath else { return }
        holdPath = nil
        await withCheckedContinuation { continuation in
            held = continuation
            onHeld?.resume()
            onHeld = nil
        }
    }

    /// False when no read satisfied `condition` before `timeout`.
    func wait(timeout: Duration = .seconds(10), until condition: @escaping () -> Bool) async -> Bool {
        guard !condition() else { return true }
        return await withCheckedContinuation { continuation in
            var resumed = false
            let resume: (Bool) -> Void = { [weak self] value in
                guard !resumed else { return }
                resumed = true
                self?.waiter = nil
                continuation.resume(returning: value)
            }
            waiter = (condition, resume)
            Task { @MainActor in
                try? await Task.sleep(for: timeout)
                resume(condition())
            }
        }
    }
}

@MainActor
private struct Fixture {
    static let subagentID = "abc123"

    let tab = UUID()
    let session = UUID().uuidString
    let dirA: URL
    let dirB: URL
    let dirC: URL
    let root = FileManager.default.temporaryDirectory.appending(path: "projects-\(UUID().uuidString)")

    var pathA: String { dirA.appending(path: "\(session).jsonl").path }
    var pathB: String { dirB.appending(path: "\(session).jsonl").path }
    var pathC: String { dirC.appending(path: "\(session).jsonl").path }

    var expectedMessageCount: Int? {
        try? TranscriptParser.parse(Data(contentsOf: URL(fileURLWithPath: pathC))).messages.count
    }

    init(parentReportsCompletion: Bool = true) throws {
        dirA = root.appending(path: "-Users-me-Repo")
        dirB = root.appending(path: "-Users-me-Repo--claude-worktrees-x")
        dirC = root.appending(path: "-Users-me-Repo--claude-worktrees-y")
        for dir in [dirA, dirB, dirC] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        var parent = Self.userLine("Start") + Self.assistantLine("On it")
        if parentReportsCompletion {
            parent += #"{"type":"user","uuid":"\#(UUID().uuidString)","isSidechain":false,"toolUseResult":{"status":"completed","agentId":"\#(Self.subagentID)","content":"the report"},"message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"the report"}]}}"# + "\n"
        }
        parent += Self.assistantLine("The subagent reported back")
        try Data(parent.utf8).write(to: URL(fileURLWithPath: pathA))

        // Ends on a tool call, so only the parent's completion makes it done.
        let subagentsDir = dirA.appending(path: "\(session)/subagents")
        try FileManager.default.createDirectory(at: subagentsDir, withIntermediateDirectories: true)
        try Data(
            #"{"type":"assistant","uuid":"s1","isSidechain":true,"message":{"role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{}}]}}"#.utf8
                + Data("\n".utf8)
        ).write(to: subagentsDir.appending(path: "agent-\(Self.subagentID).jsonl"))
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    func name(_ path: String) -> String {
        [(dirA, "A"), (dirB, "B"), (dirC, "C")].first { path.hasPrefix($0.0.path + "/") }?.1 ?? path
    }

    func renameAToB() throws {
        try FileManager.default.moveItem(atPath: pathA, toPath: pathB)
    }

    func renameBToC() throws {
        try FileManager.default.moveItem(atPath: pathB, toPath: pathC)
    }

    func moveSubagents(from source: URL, to destination: URL) throws {
        let target = destination.appending(path: session)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.moveItem(
            at: source.appending(path: "\(session)/subagents"),
            to: target.appending(path: "subagents")
        )
    }

    func appendSend(to path: String) {
        append(Self.userLine("Follow-up after the move") + Self.assistantLine("Reply after the move"), to: path)
    }

    func append(_ text: String, to path: String) {
        guard let handle = FileHandle(forWritingAtPath: path) else { return }
        defer { try? handle.close() }
        handle.seekToEndOfFile()
        handle.write(Data(text.utf8))
    }

    static func userLine(_ text: String) -> String {
        #"{"type":"user","uuid":"\#(UUID().uuidString)","isSidechain":false,"message":{"role":"user","content":"\#(text)"}}"# + "\n"
    }

    static func assistantLine(_ text: String) -> String {
        #"{"type":"assistant","uuid":"\#(UUID().uuidString)","isSidechain":false,"message":{"role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"\#(text)"}]}}"# + "\n"
    }
}
