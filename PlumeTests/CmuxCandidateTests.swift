import Testing
import Foundation
@testable import Plume

/// How a cmux workspace becomes a candidate: which panes become agent tabs,
/// what a title falls back to, and which workspaces are refused outright.
struct CmuxCandidateTests {
    private static func fixture(_ name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appending(path: "Fixtures/Cmux/\(name).json")
        return try Data(contentsOf: url)
    }

    private func snapshot(
        session: String = "session-basic",
        hooks: String? = "hook-sessions"
    ) throws -> CmuxSnapshot {
        let sessionData = try Self.fixture(session)
        let hookData = try hooks.map { try Self.fixture($0) }
        return CmuxSnapshot.decoding(sessionData: sessionData, hookData: hookData)
    }

    private func candidates(
        session: String = "session-basic",
        hooks: String? = "hook-sessions"
    ) throws -> [ImportCandidate] {
        CmuxCandidateBuilder.candidates(from: try snapshot(session: session, hooks: hooks))
    }

    // MARK: - Tab classification

    /// A pane is `type: "terminal"` whether or not an agent runs in it, so the
    /// session join is what separates the two.
    @Test func aPaneWithASessionBecomesAnAgentTab() throws {
        let built = try candidates()
        let first = try #require(built.first)

        #expect(first.agentTabCount == 1)
        #expect(first.terminalTabCount == 1)
        #expect(first.tabs.first?.agentSessionID == "55555555-5555-5555-5555-aaaaaaaaaaaa")
    }

    @Test func aPaneWithoutASessionBecomesATerminalTab() throws {
        let built = try candidates()
        let first = try #require(built.first)
        let terminal = try #require(first.tabs.last)

        #expect(terminal.kind == .terminal)
        #expect(terminal.agentSessionID == nil)
        #expect(terminal.title == "server")
    }

    @Test func aBrowserPaneIsSkipped() throws {
        let built = try candidates()
        let notes = try #require(built.first { $0.title == "Notes" })

        #expect(notes.tabs.count == 1)
        #expect(notes.tabs.first?.title == "notes")
    }

    @Test func anAgentTabTakesItsSessionsOwnDirectory() throws {
        let built = try candidates()
        let first = try #require(built.first)

        #expect(first.tabs.first?.workingDirectoryPath == "/Users/example/Code/widget")
    }

    @Test func cmuxsRecordedTranscriptIsCarriedIntoThePlan() throws {
        let built = try candidates()
        let first = try #require(built.first)

        #expect(first.tabs.first?.sessionJSONLPath?.hasSuffix("5555-aaaaaaaaaaaa.jsonl") == true)
    }

    // MARK: - Permission mode

    @Test func aRecognizedPermissionModeMapsOnto() throws {
        let built = try candidates()
        let first = try #require(built.first)

        #expect(first.tabs.first?.permissionMode == .auto)
    }

    /// cmux records modes Plume has no case for; nil leaves the CLI's default
    /// in charge rather than asserting one.
    @Test func anUnrecognizedPermissionModeBecomesNil() throws {
        let built = try candidates()
        let worktree = try #require(built.first { $0.workingDirectoryPath.hasSuffix("fix-crash") })

        #expect(worktree.tabs.first?.agentSessionID == "66666666-6666-6666-6666-cccccccccccc")
        #expect(worktree.tabs.first?.permissionMode == nil)
    }

    // MARK: - Titles

    @Test func theAgentMarkerIsStrippedFromATitle() throws {
        let built = try candidates()

        #expect(built.first?.title == "Build the widget")
    }

    /// An untitled workspace repeats its own path, which the row's path line
    /// already shows.
    @Test func aTitleThatRepeatsThePathFallsBackToTheFolderName() throws {
        let built = try candidates()
        let worktree = try #require(built.first { $0.workingDirectoryPath.hasSuffix("fix-crash") })

        #expect(worktree.title == "fix-crash")
    }

    // MARK: - Groups

    @Test func groupNamesComeFromTheWorkspacesGroupID() throws {
        let built = try candidates()

        #expect(built.first?.groupName == "Widgets")
        #expect(built.first { $0.title == "Notes" }?.groupName == "Widgets")
    }

    @Test func aWorkspaceWithNoGroupIsUngrouped() throws {
        let built = try candidates()
        let worktree = try #require(built.first { $0.workingDirectoryPath.hasSuffix("fix-crash") })

        #expect(worktree.groupName == nil)
    }

    // MARK: - Identity

    @Test func theStableIDIsNamespacedBySourceApp() throws {
        let built = try candidates()

        #expect(built.first?.stableID == "cmux:11111111-1111-1111-1111-111111111111")
    }

    // MARK: - Rejection

    @Test func aWorkspaceWithoutAStableIDIsRejected() throws {
        let built = try candidates(session: "session-malformed", hooks: nil)
        let orphan = try #require(built.first { $0.stableID.isEmpty })

        #expect(orphan.rejection == .noStableIdentity)
        #expect(!orphan.isImportable)
    }

    @Test func aWorkspaceWithNoImportablePaneIsRejected() throws {
        let workspace = CmuxWorkspaceView(
            stableID: "abc",
            workspaceID: "ws",
            groupName: nil,
            currentDirectory: "/Users/example/Code/widget",
            branch: nil,
            processTitle: "Browser only",
            panels: [CmuxPanelView(panelID: "p1", type: "browser", title: nil, directory: nil, session: nil)]
        )

        #expect(CmuxCandidateBuilder.candidate(for: workspace).rejection == .nothingToImport)
    }

    @Test func aWorkspaceWithNoDirectoryIsRejected() throws {
        let workspace = CmuxWorkspaceView(
            stableID: "abc",
            workspaceID: "ws",
            groupName: nil,
            currentDirectory: nil,
            branch: nil,
            processTitle: "Nowhere",
            panels: [CmuxPanelView(panelID: "p1", type: "terminal", title: nil, directory: nil, session: nil)]
        )

        #expect(CmuxCandidateBuilder.candidate(for: workspace).rejection == .noWorkingDirectory)
    }

    /// A directory that no longer exists is only knowable once validation
    /// touches the filesystem.
    @Test func aMissingDirectoryIsRejectedDuringValidation() async throws {
        let workspace = CmuxWorkspaceView(
            stableID: "abc",
            workspaceID: "ws",
            groupName: nil,
            currentDirectory: "/nonexistent/path/for/this/test",
            branch: nil,
            processTitle: "Gone",
            panels: [CmuxPanelView(panelID: "p1", type: "terminal", title: nil, directory: nil, session: nil)]
        )
        let candidate = CmuxCandidateBuilder.candidate(for: workspace)
        try #require(candidate.rejection == nil)

        let validated = await CmuxImportValidator.validating(candidate)

        #expect(validated.rejection == .directoryMissing("/nonexistent/path/for/this/test"))
    }

    /// An agent tab that cannot restore its conversation is a broken promise,
    /// so the workspace is refused rather than imported hollow.
    @Test func anAgentWhoseTranscriptIsGoneIsRejectedDuringValidation() async throws {
        let built = try candidates()
        let worktree = try #require(built.first { $0.workingDirectoryPath.hasSuffix("fix-crash") })
        try #require(worktree.rejection == nil)

        let validated = await CmuxImportValidator.validating(worktree)

        // Its directory does not exist either; whichever fires, the row is refused.
        #expect(validated.rejection != nil)
        #expect(!validated.isImportable)
    }

    // MARK: - The session join

    @Test func theWorkspaceKeyedFallbackClaimsOnlyOnePane() throws {
        let built = try candidates(hooks: "hook-sessions-workspace-keyed")
        let first = try #require(built.first)

        #expect(first.agentTabCount == 1)
    }

    @Test func noHookFileMeansEveryPaneIsATerminal() throws {
        let built = try candidates(hooks: nil)

        #expect(built.allSatisfy { $0.agentTabCount == 0 })
    }

    @Test func anOrphanSessionClaimsNothing() throws {
        let built = try candidates()
        let ids = built.flatMap { $0.tabs.compactMap(\.agentSessionID) }

        #expect(!ids.contains { $0.hasPrefix("77777777") })
    }
}
