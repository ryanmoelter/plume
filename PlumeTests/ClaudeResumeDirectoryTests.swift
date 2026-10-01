import Foundation
import Testing
@testable import Plume

/// A Claude Code resume runs from the directory the session was launched in,
/// which the transcript's first `cwd` records, even after the tab has moved
/// into a worktree. A fresh launch, or a resume with no transcript to read,
/// runs from wherever the tab is now.
@MainActor
struct ClaudeResumeDirectoryTests {
    private let checkout = "/Users/me/Notability"
    private let worktree = "/Users/me/Notability/.worktrees/babysit"

    private func makeTab() -> TaskTab {
        let task = WorkTask(title: "T", orderIndex: 0)
        task.workingDirectoryPath = checkout
        let tab = TaskTab(kind: .agent, orderIndex: 0, task: task)
        task.tabs = [tab]
        tab.workingDirectoryPath = worktree
        return tab
    }

    private func writeTranscript(_ lines: [String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "resume-\(UUID().uuidString).jsonl")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test func aResumeRunsFromTheTranscriptsLaunchDirectory() throws {
        let tab = makeTab()
        let url = try writeTranscript([
            #"{"type":"permission-mode","permissionMode":"plan"}"#,
            #"{"type":"user","cwd":"\#(checkout)"}"#,
            #"{"type":"assistant","cwd":"\#(worktree)"}"#,
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        tab.sessionJSONLPath = url.path

        #expect(AgentLauncher.claudeLaunchDirectory(for: tab, resumeSessionID: "abc") == checkout)
    }

    @Test func aFreshLaunchRunsFromTheTabsCurrentDirectory() throws {
        let tab = makeTab()
        let url = try writeTranscript([#"{"type":"user","cwd":"\#(checkout)"}"#])
        defer { try? FileManager.default.removeItem(at: url) }
        tab.sessionJSONLPath = url.path

        #expect(AgentLauncher.claudeLaunchDirectory(for: tab, resumeSessionID: nil) == worktree)
    }

    @Test func aResumeWithNoTranscriptRunsFromTheTabsCurrentDirectory() {
        let tab = makeTab()

        #expect(
            AgentLauncher.claudeLaunchDirectory(for: tab, resumeSessionID: "no-such-session-\(UUID())")
                == worktree
        )
    }

    @Test func reportedErrorTakesTheLastErrorLine() {
        let stderr = """
            /Users/me/.zshrc:bindkey:50: cannot bind to an empty key sequence
            Error: first
            Error: The worktree contains the directory this resume ran from.
            """

        #expect(AgentProcess.reportedError(in: stderr) == "The worktree contains the directory this resume ran from.")
    }

    @Test func stderrWithoutAnErrorLineReportsNothing() {
        #expect(AgentProcess.reportedError(in: "SessionEnd hook failed: Read-only file system") == nil)
        #expect(AgentProcess.reportedError(in: "Error:") == nil)
    }
}
