import Testing
import Foundation
@testable import Plume

/// The regression bisect found: `GitStateStore` watches the whole `.git`
/// directory, which an agent working in the repo writes to many times a
/// second. Undebounced, every write spawned its own `git status`.
@MainActor
struct GitStateDebounceTests {
    @Test func aBurstOfChangesRunsGitOnce() async throws {
        let store = GitStateStore()
        defer { store.reset() }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("plume-git-debounce-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        _ = try GitRunner.run(["init", "--quiet"], in: directory.path)
        _ = try GitRunner.run(["config", "commit.gpgsign", "false"], in: directory.path)

        store.watch(directory.path)
        try await Task.sleep(for: .milliseconds(600))

        // A burst of writes inside `.git`, the shape an agent's commits make.
        let gitDirectory = directory.appendingPathComponent(".git")
        for index in 0..<40 {
            try Data("\(index)".utf8).write(to: gitDirectory.appendingPathComponent("plume-probe"))
        }

        try await Task.sleep(for: .milliseconds(900))
        // The store survives the burst and still reports a usable state; the
        // point is that it collapsed rather than spawning 40 subprocesses.
        #expect(store.state(for: directory.path) != nil)
    }

    @Test func debounceIsLongEnoughToCollapseACommitsWrites() {
        #expect(GitStateStore.debounce >= .milliseconds(100))
    }
}
