import Testing
import Foundation
import SwiftData
@testable import Plume

/// `StartupWarmPass.directories(for:)` is the pure half of the warm pass — the
/// part that decides what to watch, independent of the stores it feeds.
@MainActor
struct StartupWarmPassTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(
            for: Schema([TaskGroup.self, WorkTask.self, TaskTab.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
    }

    @Test func aTaskWithNoAgentTabsWarmsItsOwnWorkingDirectory() throws {
        let context = ModelContext(try container())
        let task = TaskStore.createTask(in: context, siblings: [])
        task.workingDirectoryPath = "/repo/task"

        let directories = StartupWarmPass.directories(for: [task])

        #expect(directories == ["/repo/task"])
    }

    @Test func agentTabDirectoriesWinOverTheTasksOwnFolder() throws {
        let context = ModelContext(try container())
        let task = TaskStore.createTask(in: context, siblings: [])
        task.workingDirectoryPath = "/repo/task"
        TabDirectoryStore.shared.setDirectory("/repo/worktree", forTab: task.orderedTabs[0])
        defer { TabDirectoryStore.shared.reset() }

        let directories = StartupWarmPass.directories(for: [task])

        #expect(directories == ["/repo/worktree"])
    }

    @Test func directoriesAcrossManyTasksAreUnioned() throws {
        let context = ModelContext(try container())
        let first = TaskStore.createTask(in: context, siblings: [])
        first.workingDirectoryPath = "/repo/one"
        let second = TaskStore.createTask(in: context, siblings: [])
        second.workingDirectoryPath = "/repo/two"

        let directories = StartupWarmPass.directories(for: [first, second])

        #expect(directories == ["/repo/one", "/repo/two"])
    }

    @Test func aTaskWithNoDirectoryAtAllContributesNothing() throws {
        let context = ModelContext(try container())
        let task = TaskStore.createTask(in: context, siblings: [])

        let directories = StartupWarmPass.directories(for: [task])

        #expect(directories.isEmpty)
    }

    @Test func warmingTheSameDirectoryTwiceTakesOnlyOneWatch() async {
        var gitCalls: [String] = []
        var pullRequestCalls: [String] = []
        // Zeroed so the assertion waits on scheduling alone, not a race
        // against the production stagger interval.
        let pass = StartupWarmPass(
            watchGit: { gitCalls.append($0) },
            watchPullRequests: { pullRequestCalls.append($0) },
            staggerMilliseconds: 0
        )

        pass.warm(directories: ["/repo/one"])
        pass.warm(directories: ["/repo/one"])
        await Self.waitUntil { gitCalls.count == 1 && pullRequestCalls.count == 1 }

        #expect(gitCalls == ["/repo/one"])
        #expect(pullRequestCalls == ["/repo/one"])
    }

    @Test func warmingANewDirectoryLeavesAnAlreadyWarmedOneAlone() async {
        var gitCalls: [String] = []
        let pass = StartupWarmPass(
            watchGit: { gitCalls.append($0) },
            watchPullRequests: { _ in },
            staggerMilliseconds: 0
        )

        pass.warm(directories: ["/repo/one"])
        await Self.waitUntil { gitCalls.count == 1 }
        pass.warm(directories: ["/repo/one", "/repo/two"])
        await Self.waitUntil { gitCalls.count == 2 }

        #expect(gitCalls.sorted() == ["/repo/one", "/repo/two"])
        #expect(gitCalls.filter { $0 == "/repo/one" }.count == 1)
    }

    /// Polls rather than sleeping a fixed duration, since the call lands on
    /// a `Task` hop whose exact timing isn't worth pinning down. The pass
    /// itself runs with no stagger in these tests, so the wait is only for
    /// scheduling, not the production interval.
    private static func waitUntil(
        timeout: Duration = .seconds(5),
        _ condition: () -> Bool
    ) async {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}
