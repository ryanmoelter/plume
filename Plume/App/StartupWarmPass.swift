import Foundation

/// Keeps every task's directory watched from launch, so a row scrolled into
/// view later reads git and pull request state that is already warm instead
/// of starting the fetch itself.
///
/// `GitStateStore` and `PullRequestStore` are refcounted, and `TaskRowView`
/// takes and releases its own watch as it scrolls on- and off-screen. This
/// holds one extra watch per directory for the app's lifetime, so the
/// refcount never drops to zero and the row's own watch only adds to a poll
/// already running rather than starting one.
@MainActor
final class StartupWarmPass {
    static let shared = StartupWarmPass()

    private var warmedDirectories: Set<String> = []
    /// Injectable so a test can assert what got warmed without touching the
    /// shared stores' own state.
    private let watchGit: @MainActor (String) -> Void
    private let watchPullRequests: @MainActor (String) -> Void
    /// Milliseconds between one directory's watch and the next. Injectable so
    /// a test isn't stretched out over the production stagger.
    private let staggerMilliseconds: Int

    init(
        watchGit: @escaping @MainActor (String) -> Void = { GitStateStore.shared.watch($0) },
        watchPullRequests: @escaping @MainActor (String) -> Void = { PullRequestStore.shared.watch($0) },
        // Long enough to spread a large task list's launches across several
        // seconds rather than one burst, short enough that even a 50-task
        // list finishes warming well inside the time a user spends looking
        // at the sidebar before scrolling.
        staggerMilliseconds: Int = 50
    ) {
        self.watchGit = watchGit
        self.watchPullRequests = watchPullRequests
        self.staggerMilliseconds = staggerMilliseconds
    }

    /// The distinct directories worth warming: each task's own agent-tab
    /// directories, falling back to its working directory — the same rule
    /// `TaskRowView.directories` uses, so the warm pass never fetches a
    /// directory no row would ask for.
    static func directories(for tasks: [WorkTask]) -> Set<String> {
        var directories: Set<String> = []
        for task in tasks {
            let agentTabDirectories = task.orderedTabs
                .filter { $0.kind == .agent }
                .map { TabDirectoryStore.shared.directory(for: $0) }
            let resolved = TaskRowDetails.distinctDirectories(
                agentTabDirectories: agentTabDirectories,
                taskDirectory: task.workingDirectoryPath
            )
            directories.formUnion(resolved)
        }
        return directories
    }

    /// Takes one watch per directory on both stores, skipping any directory
    /// already warmed. Idempotent, so a caller can run it again after tasks
    /// change without double-counting a directory's refcount.
    ///
    /// Each directory's git watch starts its own `Task`, spread a tick apart
    /// rather than all at once: `GitService` already serializes its
    /// subprocesses one at a time, so this bounds how many `Task`s and
    /// `.git` `FileWatcher`s stand up in the same run-loop turn instead of
    /// bounding subprocess concurrency, which the actor already bounds.
    func warm(directories: Set<String>) {
        let toWarm = directories.subtracting(warmedDirectories)
        guard !toWarm.isEmpty else { return }
        warmedDirectories.formUnion(toWarm)

        for (index, directory) in toWarm.sorted().enumerated() {
            let delay = Duration.milliseconds(index * staggerMilliseconds)
            Task {
                try? await Task.sleep(for: delay)
                watchGit(directory)
                watchPullRequests(directory)
            }
        }
    }

    /// For tests: drops every warmed directory without releasing the watches
    /// it took, since only the shared stores' own `reset()` can do that.
    func reset() {
        warmedDirectories.removeAll()
    }
}
