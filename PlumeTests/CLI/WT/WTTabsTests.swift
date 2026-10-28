import Foundation
import Testing
@testable import Plume

/// Where a new or opened worktree goes. Inside Plume, `co`, `cob`, `bg` and
/// `open` ask the app for a terminal tab in the calling task, or a new task
/// with `--task`. Outside Plume, or when the app refuses or is unreachable,
/// they print a `cd` hint instead. A failed tab request never escalates to a
/// task. Replaces the cmux and Ghostty drivers of `test_wt_tabs.py`.
struct WTTabsTests {
    private static let tabID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private static let taskID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private static let insidePlume = [CLISocket.tabIDEnvironmentKey: tabID.uuidString, CLISocket.taskIDEnvironmentKey: taskID.uuidString]
    private static let hint = "wt: /wt/foo\nwt: (cd \"/wt/foo\")\n"

    private func opener(_ client: FakePlumeAppClient, environment: [String: String] = insidePlume) -> (PlumeTabOpener, BufferConsole) {
        let console = BufferConsole()
        return (PlumeTabOpener(client: client, environment: environment, console: console), console)
    }

    // MARK: caller

    @Test func theTabIDWinsOverTheTaskID() {
        #expect(PlumeCaller.from(environment: Self.insidePlume) == .tab(Self.tabID))
    }

    @Test func aTaskIDAloneNamesTheTask() {
        #expect(PlumeCaller.from(environment: [CLISocket.taskIDEnvironmentKey: Self.taskID.uuidString]) == .task(Self.taskID))
    }

    @Test func noOrMalformedIDsMeanNoCaller() {
        #expect(PlumeCaller.from(environment: [:]) == nil)
        #expect(PlumeCaller.from(environment: [CLISocket.tabIDEnvironmentKey: "not-a-uuid"]) == nil)
    }

    // MARK: opener

    @Test func insidePlumeTheDefaultIsOneTabInTheCallingTask() {
        let client = FakePlumeAppClient()
        let (tabs, console) = opener(client)
        #expect(tabs.canOpenTabs)
        tabs.open("/wt/foo", asTask: false)
        #expect(client.requests == [.tab(directory: "/wt/foo", caller: .tab(Self.tabID))])
        #expect(console.stdout == "")
    }

    @Test func asTaskMakesOneTaskRequest() {
        let client = FakePlumeAppClient()
        let (tabs, console) = opener(client)
        tabs.open("/wt/foo", asTask: true)
        #expect(client.requests == [.task(worktreePath: "/wt/foo", caller: .tab(Self.tabID))])
        #expect(console.stdout == "")
    }

    @Test func aFailedTabRequestNeverEscalatesToATask() {
        let client = FakePlumeAppClient(tabResult: false)
        let (tabs, console) = opener(client)
        tabs.open("/wt/foo", asTask: false)
        #expect(client.requests == [.tab(directory: "/wt/foo", caller: .tab(Self.tabID))])
        #expect(console.stdout == Self.hint)
    }

    @Test func aRefusedTaskRequestPrintsTheHint() {
        let client = FakePlumeAppClient(tabResult: false, taskResult: false)
        let (tabs, console) = opener(client)
        tabs.open("/wt/foo", asTask: true)
        #expect(client.requests.first == .task(worktreePath: "/wt/foo", caller: .tab(Self.tabID)))
        #expect(console.stdout == Self.hint)
    }

    @Test(arguments: [false, true])
    func outsidePlumeThereAreNoRequestsOnlyTheHint(_ asTask: Bool) {
        let client = FakePlumeAppClient()
        let (tabs, console) = opener(client, environment: [:])
        #expect(!tabs.canOpenTabs)
        tabs.open("/wt/foo", asTask: asTask)
        #expect(client.requests.isEmpty)
        #expect(console.stdout == Self.hint)
    }

    @Test func withOnlyATaskIDTheTabGoesToThatTask() {
        let client = FakePlumeAppClient()
        let (tabs, _) = opener(client, environment: [CLISocket.taskIDEnvironmentKey: Self.taskID.uuidString])
        tabs.open("/wt/foo", asTask: false)
        #expect(client.requests == [.tab(directory: "/wt/foo", caller: .task(Self.taskID))])
    }

    @Test func thePathReachesTheClientVerbatim() {
        let path = "/wt/we\"ird\\dir"
        let client = FakePlumeAppClient()
        let (tabs, _) = opener(client)
        tabs.open(path, asTask: false)
        #expect(client.requests == [.tab(directory: path, caller: .tab(Self.tabID))])
    }

    @Test(arguments: [false, true])
    func aTabWhoseAppExportedNoSocketPrintsTheHint(_ asTask: Bool) {
        let console = BufferConsole()
        let tabs = PlumeTabOpener(
            client: SocketPlumeAppClient(socketPath: CLISocket.resolvedPath(environment: Self.insidePlume)),
            environment: Self.insidePlume,
            console: console
        )
        tabs.open("/wt/foo", asTask: asTask)
        #expect(console.stdout == Self.hint)
    }

    // MARK: open

    private func openContext() -> FakeWTContext {
        FakeWTContext(worktrees: [wtRow("foo", "ryanm/foo", "0")])
    }

    @Test func openDefaultsToATabInTheCallingTask() throws {
        let ctx = openContext()
        try WT.open(ctx, ["foo"])
        #expect(ctx.recordingTabs.opened == [.init(directory: "\(ctx.newWorktreesDirectory)/foo", asTask: false)])
    }

    @Test(arguments: ["--task", "--workspace"])
    func openThreadsTheTaskFlag(_ flag: String) throws {
        let ctx = openContext()
        try WT.open(ctx, ["foo", flag])
        #expect(ctx.recordingTabs.opened == [.init(directory: "\(ctx.newWorktreesDirectory)/foo", asTask: true)])
    }

    @Test func surfaceIsAcceptedAsANoOp() throws {
        let ctx = openContext()
        try WT.open(ctx, ["foo", "--surface"])
        #expect(ctx.recordingTabs.opened == [.init(directory: "\(ctx.newWorktreesDirectory)/foo", asTask: false)])
    }

    @Test func openRejectsAnUnknownFlag() {
        let ctx = openContext()
        #expect(cliFailure { try WT.open(ctx, ["foo", "--no-tab"]) }?.message == "unknown flag: --no-tab")
        #expect(ctx.recordingTabs.opened.isEmpty)
    }

    // MARK: checkout

    private func checkoutContext() -> FakeWTContext {
        FakeWTContext(prefix: "ryanm/", baseBranch: "main")
    }

    @Test func cobOpensATabInTheNewWorktree() throws {
        let ctx = checkoutContext()
        try WT.checkout(ctx, ["x"], create: true)
        let path = "\(ctx.newWorktreesDirectory)/x"
        #expect(ctx.fakeGit.added == [.init(path: path, branch: "ryanm/x", new: true, baseRef: "origin/main")])
        #expect(ctx.fakeGit.fetched == ["main"])
        #expect(ctx.ensuredWorktreesDirectory)
        #expect(ctx.recordingTabs.opened == [.init(directory: path, asTask: false)])
    }

    @Test(arguments: ["--task", "--workspace"])
    func checkoutThreadsTheTaskFlag(_ flag: String) throws {
        let ctx = checkoutContext()
        try WT.checkout(ctx, ["-b", "x", flag])
        #expect(ctx.recordingTabs.opened == [.init(directory: "\(ctx.newWorktreesDirectory)/x", asTask: true)])
    }

    @Test func noTabOpensNothing() throws {
        let ctx = checkoutContext()
        try WT.checkout(ctx, ["-b", "x", "--no-tab"])
        #expect(ctx.fakeGit.added.count == 1)
        #expect(ctx.recordingTabs.opened.isEmpty)
    }

    @Test func checkoutOfAnExistingBranchMatchesItsSuffix() throws {
        let ctx = FakeWTContext(prefix: "ryanm/", branches: ["ryanm/wt"], baseBranch: "main")
        try WT.checkout(ctx, ["wt", "--no-tab"])
        #expect(ctx.fakeGit.added == [.init(path: "\(ctx.newWorktreesDirectory)/wt", branch: "ryanm/wt", new: false, baseRef: nil)])
        #expect(ctx.buffer.stdout.contains("wt: matched wt → ryanm/wt"))
    }

    // MARK: switch

    @Test func switchInsidePlumeOpensATab() throws {
        let ctx = FakeWTContext(worktrees: [wtRow("foo", "ryanm/foo", "0")], canOpenTabs: true)
        try WT.switchTo(ctx, ["foo"])
        #expect(ctx.recordingTabs.opened == [.init(directory: "\(ctx.newWorktreesDirectory)/foo", asTask: false)])
    }

    @Test func switchOutsidePlumeNamesTheWrapper() {
        let ctx = FakeWTContext(worktrees: [wtRow("foo", "ryanm/foo", "0")], canOpenTabs: false)
        let failure = cliFailure { try WT.switchTo(ctx, ["foo"]) }
        #expect(failure?.message == """
            switch needs a shell function to cd this shell, which a subprocess cannot do. Add to ~/.zshrc:

              eval "$(plume init zsh --aliases)"

            Then reload and run bare `wt switch`; `plume wt switch` never changes directory.
            For a plain path (scripts, other shells), use `plume wt path`.
            """)
        #expect(ctx.recordingTabs.opened.isEmpty)
    }
}
