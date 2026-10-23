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
    @Test func additionsSkipSymlinkedSpellingsAndReportWhatIsNotAFolder() {
        let found = AdditionalDirectories.additions(
            ["/private/tmp", "/nonexistent-plume-folder", "/usr/", "/usr"],
            to: ["/tmp"],
            relativeTo: nil
        )
        #expect(found.additions == ["/usr"])
        #expect(found.rejected == ["/nonexistent-plume-folder"])
    }

    @Test func listOrderNeverForcesARestart() {
        #expect(!AdditionalDirectories.needsRestart(launched: ["/a", "/b"], stored: ["/b", "/a"], launchDirectory: nil))
        #expect(!AdditionalDirectories.needsRestart(launched: ["/a"], stored: ["/a", "/repo"], launchDirectory: "/repo"))
        #expect(AdditionalDirectories.needsRestart(launched: ["/a", "/b"], stored: ["/b"], launchDirectory: nil))
    }

    /// Removing a launched folder and keeping it again appends it at the end.
    @Test func keepingARemovedFolderNeedsNoRestart() async {
        let tab = TaskTab(kind: .agent, orderIndex: 0)
        tab.additionalDirectories = ["/usr", "/bin"]
        AdditionalDirectoryStore.remove("/usr", from: tab)
        #expect(tab.additionalDirectories == ["/bin"])
        await withScratchDefaults { await AdditionalDirectoryStore.add(["/usr"], to: tab, history: $0) }
        #expect(tab.additionalDirectories == ["/bin", "/usr"])
        #expect(!AdditionalDirectories.needsRestart(
            launched: ["/usr", "/bin"], stored: tab.additionalDirectories, launchDirectory: nil
        ))
    }

    @Test func adoptedFoldersJoinTheTabsList() async {
        let tab = TaskTab(kind: .agent, orderIndex: 0)
        tab.additionalDirectories = ["/a"]
        await withScratchDefaults { AdditionalDirectoryStore.adopt(["/granted", "/a/"], into: tab, history: $0) }
        #expect(tab.additionalDirectories == ["/a", "/granted"])
    }

    @Test func linkingAFolderRecordsItOutsideTheProjectHistory() async {
        let tab = TaskTab(kind: .agent, orderIndex: 0)
        await withScratchDefaults { defaults in
            defaults.set(["/repo"], forKey: "recentRepositories")
            await AdditionalDirectoryStore.add(["/usr", "/nonexistent-plume-folder"], to: tab, history: defaults)
            AdditionalDirectoryStore.adopt(["/bin/"], into: tab, history: defaults)
            #expect(RecentLinkedFolders.load(from: defaults) == ["/bin", "/usr"])
            #expect(RecentFolders.load(from: defaults) == ["/repo"])
        }
    }

    private func withScratchDefaults<T>(_ body: (UserDefaults) async -> T) async -> T {
        let name = "plume-linked-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        return await body(defaults)
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

    @Test func rowsMergeSymlinkedSpellings() {
        let rows = AdditionalDirectories.rows(
            workingDirectory: "/repo",
            added: ["/private/tmp", "/tmp"],
            launched: nil
        )
        #expect(rows == [
            FolderRow(path: "/repo", kind: .workingDirectory, pending: .none),
            FolderRow(path: "/private/tmp", kind: .added, pending: .none)
        ])
    }

    @Test func marksChangesWaitingOnTheTurn() {
        let rows = AdditionalDirectories.rows(
            workingDirectory: "/repo",
            added: ["/kept", "/new"],
            launched: ["/kept", "/gone"]
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
            launched: []
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
        session.restartWhenIdle { restarts += 1; return true }
        #expect(session.isRestartPending)

        session.handle(try decode(result))

        #expect(restarts == 1)
        #expect(!session.isRestartPending)
        #expect(session.restartedAtTurnEnd)
    }

    @Test func anIdleSessionRestartsAtOnce() {
        let (session, _) = makeSession()
        var restarts = 0
        session.restartWhenIdle { restarts += 1; return true }
        #expect(restarts == 1)
        #expect(!session.restartedAtTurnEnd)
    }

    @Test func aPendingRestartRunsOnceSubagentsFinish() async throws {
        let (session, engine) = makeSession()
        session.handle(try decode(mainAssistant))
        engine.setSubagentActivity(tabID: session.tabID, working: true)
        var restarts = 0
        session.restartWhenIdle { restarts += 1; return true }

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
        session.restartWhenIdle { restarts += 1; return true }
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
        session.restartWhenIdle { restarts += 1; return true }

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
        session.restartWhenIdle { restarts += 1; return true }

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
        session.restartWhenIdle { restarts += 1; return true }
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
        session.restartWhenIdle { restarts += 1; return true }
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
        session.restartWhenIdle { true }
        #expect(AdditionalDirectoryStore.canRestartNow(session))

        session.debugMarkAsFork()
        #expect(!AdditionalDirectoryStore.canRestartNow(session))
    }

    @Test func aRestartThatCannotLaunchLeavesTheQueueToThisProcess() throws {
        let (session, _) = makeSession()
        let userTurns = recordUserTurns(of: session)
        session.handle(try decode(mainAssistant))
        session.restartWhenIdle { false }
        _ = session.submit(blocks: [.text("later")])

        session.handle(try decode(result))

        #expect(userTurns().count == 1)
        #expect(!session.restartedAtTurnEnd)
        #expect(!session.isRestartPending)
    }

    private static let backgroundTaskRunning = #"{"type":"system","subtype":"background_tasks_changed","tasks":[{"task_id":"b1","run_id":"r1","task_type":"local_bash","description":"clock"}],"session_id":"s"}"#
    private static let backgroundTasksDone = #"{"type":"system","subtype":"background_tasks_changed","tasks":[],"session_id":"s"}"#

    private func waitForBackgroundTasksToFinish(grace: Duration) throws -> (HeadlessSession, () -> Int) {
        let (session, _) = makeSession(backgroundTasks: BackgroundTaskTracker())
        session.subagentWakeGrace = grace
        session.handle(try decode(Self.backgroundTaskRunning))
        var restarts = 0
        session.restartWhenIdle { restarts += 1; return true }
        session.handle(try decode(Self.backgroundTasksDone))
        return (session, { restarts })
    }

    @Test func aRestartWaitsOutTheWakeGraceAfterTheLastBackgroundTask() async throws {
        let (session, restarts) = try waitForBackgroundTasksToFinish(grace: .seconds(60))
        await settle()
        #expect(restarts() == 0)
        #expect(session.restartBlockers == [.backgroundTasks])
    }

    /// The grace is a wall-clock wait by design, standing in for the
    /// `<task-notification>` turn the CLI may start, so this polls.
    @Test func aRestartFiresOnceTheWakeGraceEnds() async throws {
        let (session, restarts) = try waitForBackgroundTasksToFinish(grace: .milliseconds(50))
        for _ in 0..<100 where restarts() == 0 {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(restarts() == 1)
        #expect(!session.isRestartPending)
    }

    @Test func initAdoptsFoldersItWasNotLaunchedWith() throws {
        let (session, _) = makeSession()
        var adopted: [String] = []
        session.onAdoptDirectories = { adopted += $0 }
        let line = #"{"type":"system","subtype":"init","session_id":"s","cwd":"/repo","additional_directories":["/granted","/granted/"]}"#

        session.handle(try decode(line))

        #expect(adopted == ["/granted"])
        #expect(session.launchAdditionalDirectories == ["/granted"])
    }

    @Test func theCostMeterNeverStepsBackAcrossARestart() throws {
        let (previous, _) = makeSession()
        previous.handle(try decode(mainAssistant))
        previous.handle(try decode(#"{"type":"result","subtype":"success","is_error":false,"result":"ok","total_cost_usd":0.5}"#))
        let (resumed, _) = makeSession()

        resumed.inherit(from: previous)
        #expect(resumed.sessionCostUSD == 0.5)
        resumed.handle(try decode(mainAssistant))
        resumed.handle(try decode(#"{"type":"result","subtype":"success","is_error":false,"result":"ok","total_cost_usd":0.25}"#))

        #expect(resumed.sessionCostUSD == 0.5)
    }

    @Test func stoppingDropsAPendingRestart() throws {
        let (session, _) = makeSession()
        session.handle(try decode(mainAssistant))
        session.restartWhenIdle { true }
        session.stop()
        #expect(!session.isRestartPending)
    }
}
