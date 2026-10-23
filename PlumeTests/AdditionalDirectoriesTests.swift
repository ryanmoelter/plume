import Foundation
import Testing
@testable import Plume

/// A tab's `--add-dir` list: how it is normalized, how it reaches both CLIs'
/// argv, how `/add-dir` parses, and how the info pane sorts the folders a
/// session reports into the tab's own and everyone else's.
@MainActor
struct AdditionalDirectoriesTests {
    private let home = NSHomeDirectory()

    // MARK: - Normalizing the list

    @Test func expandsTildeAndStandardizes() {
        #expect(AdditionalDirectories.normalized("~/src/../docs/") == home + "/docs")
        #expect(AdditionalDirectories.normalized("  /a/./b  ") == "/a/b")
    }

    @Test func resolvesARelativePathAgainstTheBase() {
        #expect(AdditionalDirectories.normalized("lib", relativeTo: "/repo") == "/repo/lib")
        #expect(AdditionalDirectories.normalized("lib") == nil)
        #expect(AdditionalDirectories.normalized("   ") == nil)
    }

    @Test func listDedupesAndDropsTheWorkingDirectory() {
        let list = AdditionalDirectories.list(
            ["/repo", "/other", "/other/", "~/x", "\(home)/x", "/repo/../repo"],
            excluding: "/repo/"
        )
        #expect(list == ["/other", home + "/x"])
    }

    /// `/tmp` is a symlink to `/private/tmp`, so the two are one folder.
    @Test func listTreatsSymlinkedSpellingsAsOneFolder() {
        #expect(AdditionalDirectories.list(["/tmp", "/private/tmp"], excluding: nil) == ["/tmp"])
        #expect(AdditionalDirectories.list(["/private/tmp"], excluding: "/tmp").isEmpty)
    }

    @Test func tabRoundTripsTheList() {
        let tab = TaskTab(kind: .agent, orderIndex: 0)
        #expect(tab.additionalDirectories.isEmpty)
        tab.additionalDirectories = ["/a", "/b c"]
        #expect(tab.additionalDirectories == ["/a", "/b c"])
        tab.additionalDirectories = []
        #expect(tab.additionalDirectoriesData == nil)
    }

    // MARK: - Launch arguments

    /// A bare `--add-dir <path>` is variadic and would swallow the word after
    /// it; the `=` form binds exactly one path.
    @Test func headlessPassesOneBoundFlagPerPath() throws {
        let arguments = HeadlessCommand.arguments(
            resumeSessionID: "abc",
            permissionMode: .plan,
            settingsPath: "/s.json",
            addDirectories: ["/a", "/b c"]
        )
        #expect(arguments.filter { $0.hasPrefix("--add-dir") } == ["--add-dir=/a", "--add-dir=/b c"])
        #expect(!arguments.contains("--add-dir"))
        let resume = try #require(arguments.firstIndex(of: "--resume"))
        #expect(arguments[resume + 1] == "abc")
    }

    @Test func headlessPassesNoFlagWithoutFolders() {
        let arguments = HeadlessCommand.arguments(resumeSessionID: nil, permissionMode: .plan, settingsPath: nil)
        #expect(!arguments.contains { $0.hasPrefix("--add-dir") })
    }

    @Test func terminalQuotesEachPathAndKeepsThePromptPositional() {
        let provider = ClaudeCodeProvider(additionalDirectories: ["/a", "/it's here"])
        let launch = provider.launchCommand(firstMessage: "hi", resumeSessionID: nil)
        #expect(launch.command == LoginShellCommand.wrap(#"claude --add-dir='/a' --add-dir='/it'\''s here' 'hi'"#))
    }

    // MARK: - `/add-dir`

    @Test func parsesAddDirectory() {
        #expect(PlumeSlashCommand.parse("/add-dir ~/src") == .addDirectory(path: "~/src"))
        #expect(PlumeSlashCommand.parse("  /add-dir   /a b/c  ") == .addDirectory(path: "/a b/c"))
        #expect(PlumeSlashCommand.parse(#"/add-dir "/a b""#) == .addDirectory(path: "/a b"))
        #expect(PlumeSlashCommand.parse("/add-dir '/a b'") == .addDirectory(path: "/a b"))
        #expect(PlumeSlashCommand.parse(#"/add-dir /a\ b"#) == .addDirectory(path: "/a b"))
    }

    /// An empty path opens the folder picker rather than reaching the CLI.
    @Test func parsesBareAddDirectoryAsEmpty() {
        #expect(PlumeSlashCommand.parse("/add-dir") == .addDirectory(path: ""))
    }

    @Test func multilineAddDirectoryIsAMessage() {
        #expect(PlumeSlashCommand.parse("/add-dir /a\nand then") == nil)
        #expect(PlumeSlashCommand.parse("/add-directory /a") == nil)
    }

    // MARK: - `system/init`

    @Test func decodesAdditionalDirectoriesFromInit() throws {
        let line = #"{"type":"system","subtype":"init","session_id":"s","cwd":"/repo","additional_directories":["/tmp","/b"]}"#
        guard case .initialized(let info) = try #require(StreamJSONDecoder.decode(line: line)) else {
            Issue.record("Not an init")
            return
        }
        #expect(info.additionalDirectories == ["/tmp", "/b"])
    }

    @Test func initWithoutTheFieldReportsNone() throws {
        let line = #"{"type":"system","subtype":"init","session_id":"s"}"#
        guard case .initialized(let info) = try #require(StreamJSONDecoder.decode(line: line)) else {
            Issue.record("Not an init")
            return
        }
        #expect(info.additionalDirectories.isEmpty)
    }

    // MARK: - Info pane rows

    @Test func classifiesReportedFolders() {
        let rows = AdditionalDirectories.rows(
            workingDirectory: "/repo",
            added: ["/private/tmp"],
            launched: nil,
            reported: ["/tmp", "/repo", "/granted"]
        )
        #expect(rows == [
            FolderRow(path: "/repo", kind: .workingDirectory, pending: .none),
            FolderRow(path: "/private/tmp", kind: .added, pending: .none),
            FolderRow(path: "/granted", kind: .foreign, pending: .none)
        ])
    }

    @Test func marksChangesWaitingOnTheTurn() {
        let rows = AdditionalDirectories.rows(
            workingDirectory: "/repo",
            added: ["/kept", "/new"],
            launched: ["/kept", "/gone"],
            reported: ["/kept", "/gone"]
        )
        #expect(rows == [
            FolderRow(path: "/repo", kind: .workingDirectory, pending: .none),
            FolderRow(path: "/kept", kind: .added, pending: .none),
            FolderRow(path: "/new", kind: .added, pending: .addsAfterTurn),
            FolderRow(path: "/gone", kind: .added, pending: .removesAfterTurn)
        ])
    }

    /// `EnterWorktree` moved the session out of `/repo`, where it launched.
    @Test func showsEveryStoredFolderAndNeverMarksTheLaunchFolderPending() {
        let rows = AdditionalDirectories.rows(
            workingDirectory: "/repo/wt",
            launchDirectory: "/repo",
            added: ["/repo/wt", "/repo", "/new"],
            launched: [],
            reported: []
        )
        #expect(rows == [
            FolderRow(path: "/repo/wt", kind: .workingDirectory, pending: .none),
            FolderRow(path: "/repo/wt", kind: .added, pending: .addsAfterTurn),
            FolderRow(path: "/repo", kind: .added, pending: .none),
            FolderRow(path: "/new", kind: .added, pending: .addsAfterTurn)
        ])
    }

    // MARK: - Restart on change

    private func decode(_ line: String) throws -> StreamJSONMessage {
        try #require(StreamJSONDecoder.decode(line: line))
    }

    private func makeSession(
        backgroundTasks tracker: BackgroundTaskTracker? = nil
    ) -> (HeadlessSession, StatusEngine) {
        let backgroundTasks = tracker ?? BackgroundTaskTracker()
        let engine = StatusEngine(backgroundTasks: backgroundTasks)
        let session = HeadlessSession(
            tabID: UUID(), taskID: UUID(), statusEngine: engine, backgroundTasks: backgroundTasks
        )
        engine.register(tabID: session.tabID, taskID: session.taskID)
        session.queuedMessageDelivery = { .endOfTurn }
        return (session, engine)
    }

    /// The idle check reruns from an observation callback, one main-actor
    /// hop after the change.
    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    private let mainAssistant = #"{"type":"assistant","parent_tool_use_id":null,"message":{"role":"assistant","content":[{"type":"text","text":"ok"}]}}"#
    private let result = #"{"type":"result","subtype":"success","is_error":false,"result":"ok"}"#

    @Test func aPendingRestartRunsWhenTheTurnEnds() throws {
        let (session, _) = makeSession()
        session.handle(try decode(mainAssistant))
        #expect(session.isBusy)
        var restarts = 0
        session.restartWhenIdle { restarts += 1 }
        #expect(session.isRestartPending)

        session.handle(try decode(result))

        #expect(restarts == 1)
        #expect(!session.isRestartPending)
        #expect(session.restartedAtTurnEnd)
    }

    @Test func anIdleSessionRestartsAtOnce() {
        let (session, _) = makeSession()
        var restarts = 0
        session.restartWhenIdle { restarts += 1 }
        #expect(restarts == 1)
        #expect(!session.restartedAtTurnEnd)
    }

    @Test func aPendingRestartRunsOnceSubagentsFinish() async throws {
        let (session, engine) = makeSession()
        session.handle(try decode(mainAssistant))
        engine.setSubagentActivity(tabID: session.tabID, working: true)
        var restarts = 0
        session.restartWhenIdle { restarts += 1 }

        session.handle(try decode(result))
        await settle()
        #expect(restarts == 0)
        #expect(session.isRestartPending)

        engine.setSubagentActivity(tabID: session.tabID, working: false)
        await settle()

        #expect(restarts == 1)
        #expect(!session.isRestartPending)
    }

    @Test func aPendingRestartRunsOnceBackgroundTasksFinish() async {
        let tracker = BackgroundTaskTracker()
        let (session, _) = makeSession(backgroundTasks: tracker)
        tracker.replaceLive(tabID: session.tabID, entries: [
            BackgroundTaskTracker.Entry(id: "m1", kind: .monitor, startedAt: Date(), expiresAt: nil)
        ])
        var restarts = 0
        session.restartWhenIdle { restarts += 1 }
        #expect(session.isBusy)
        #expect(restarts == 0)

        tracker.replaceLive(tabID: session.tabID, entries: [])
        await settle()

        #expect(restarts == 1)
    }

    private func recordUserTurns(of session: HeadlessSession) -> () -> [String] {
        var lines: [String] = []
        session.debugLineSink = { lines.append($0) }
        return { lines.filter { $0.contains(#""type":"user""#) } }
    }

    @Test func aMessageSentWhileBackgroundTasksHoldARestartGoesNow() {
        let tracker = BackgroundTaskTracker()
        let (session, _) = makeSession(backgroundTasks: tracker)
        let userTurns = recordUserTurns(of: session)
        tracker.replaceLive(tabID: session.tabID, entries: [
            BackgroundTaskTracker.Entry(id: "m1", kind: .monitor, startedAt: Date(), expiresAt: nil)
        ])
        var restarts = 0
        session.restartWhenIdle { restarts += 1 }

        let delivery = session.submit(blocks: [.text("now")])

        #expect(delivery == .sent)
        #expect(userTurns().count == 1)
        #expect(restarts == 0)
        #expect(session.isRestartPending)
    }

    /// The restart fires at the turn's end before the queue drains, so the
    /// new process gets the message.
    @Test func aMessageQueuedBehindATurnWaitsForTheNewProcess() throws {
        let (session, _) = makeSession()
        let userTurns = recordUserTurns(of: session)
        session.handle(try decode(mainAssistant))
        var restarts = 0
        session.restartWhenIdle { restarts += 1 }

        #expect(session.submit(blocks: [.text("later")]) == .queued)
        session.handle(try decode(result))

        #expect(restarts == 1)
        #expect(userTurns().isEmpty)
        #expect(session.queuedMessages.count == 1)
    }

    @Test func anUnstartedForkWithARestartWaitingSendsItsFirstMessage() {
        let (session, _) = makeSession()
        let userTurns = recordUserTurns(of: session)
        session.debugMarkAsFork()
        var restarts = 0
        session.restartWhenIdle { restarts += 1 }
        #expect(session.restartBlockers == [.unstartedFork])

        #expect(session.submit(blocks: [.text("first")]) == .sent)
        #expect(userTurns().count == 1)
        #expect(restarts == 0)
    }

    @Test func cancellingARestartStrandsNoQueuedMessage() throws {
        let (session, _) = makeSession()
        let userTurns = recordUserTurns(of: session)
        session.handle(try decode(mainAssistant))
        var restarts = 0
        session.restartWhenIdle { restarts += 1 }
        _ = session.submit(blocks: [.text("later")])

        session.cancelPendingRestart()
        session.handle(try decode(result))

        #expect(restarts == 0)
        #expect(userTurns().count == 1)
        #expect(session.queuedMessages.isEmpty)
    }

    @Test func blockersSetTheNoteAndWhatRestartNowStops() {
        let turn = FolderRestartFacts(blockers: [.turn, .backgroundTasks], canRestartNow: false)
        #expect(turn.note == "Applies after this turn")

        let background = FolderRestartFacts(blockers: [.subagents, .backgroundTasks], canRestartNow: true)
        #expect(background.note == "Applies when subagents finish")
        #expect(background.restartNowHelp
            == "Apply the folder change now, stopping the subagents and stopping the background tasks")

        let side = FolderRestartFacts(blockers: [.sideQuestion], canRestartNow: true)
        #expect(side.note == "Applies when the side question is answered")
        #expect(side.restartNowHelp == "Apply the folder change now, dropping the side question")
    }

    @Test func onlyBackgroundWorkCanBeCutShort() {
        let (session, engine) = makeSession()
        engine.setSubagentActivity(tabID: session.tabID, working: true)
        session.restartWhenIdle {}
        #expect(AdditionalDirectoryStore.canRestartNow(session))

        session.debugMarkAsFork()
        #expect(!AdditionalDirectoryStore.canRestartNow(session))
    }

    @Test func stoppingDropsAPendingRestart() throws {
        let (session, _) = makeSession()
        session.handle(try decode(mainAssistant))
        session.restartWhenIdle {}
        session.stop()
        #expect(!session.isRestartPending)
    }
}
