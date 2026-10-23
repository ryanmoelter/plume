import Foundation
import Testing
@testable import Plume

/// The add-folder menu's history of linked folders, and which folders the
/// menu offers a conversation.
struct RecentLinkedFoldersTests {
    private func withDefaults(_ body: (UserDefaults) -> Void) {
        let name = "plume-recent-linked-tests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: name) else { return }
        defer { defaults.removePersistentDomain(forName: name) }
        body(defaults)
    }

    // MARK: - History

    @Test func newestComesFirst() {
        withDefaults { defaults in
            RecentLinkedFolders.remember(["/a"], in: defaults)
            RecentLinkedFolders.remember(["/b", "/c"], in: defaults)
            #expect(RecentLinkedFolders.load(from: defaults) == ["/b", "/c", "/a"])
        }
    }

    @Test func relinkingMovesAFolderToTheFrontOnce() {
        withDefaults { defaults in
            RecentLinkedFolders.remember(["/a", "/b"], in: defaults)
            RecentLinkedFolders.remember(["/b/"], in: defaults)
            #expect(RecentLinkedFolders.load(from: defaults) == ["/b", "/a"])
        }
    }

    @Test func keepsOnlyTheMostRecent() {
        withDefaults { defaults in
            for index in 0..<(RecentLinkedFolders.limit + 3) {
                RecentLinkedFolders.remember(["/folder\(index)"], in: defaults)
            }
            let stored = RecentLinkedFolders.load(from: defaults)
            #expect(stored.count == RecentLinkedFolders.limit)
            #expect(stored.first == "/folder\(RecentLinkedFolders.limit + 2)")
            #expect(stored.last == "/folder3")
        }
    }

    @Test func neverTouchesTheProjectHistory() {
        withDefaults { defaults in
            RecentFolders.remember("/repo", in: defaults)
            RecentLinkedFolders.remember(["/linked"], in: defaults)
            #expect(RecentFolders.load(from: defaults) == ["/repo"])
            #expect(RecentLinkedFolders.load(from: defaults) == ["/linked"])
        }
    }

    // MARK: - Candidates

    @Test func leavesOutLinkedFoldersAndTheWorkingDirectory() {
        let candidates = AddFolderCandidates(
            recentFolders: ["/linked", "/docs", "/repo"],
            recentProjects: ["/repo/", "/other", "/linked"],
            linked: ["/linked/"],
            workingDirectory: "/repo"
        )
        #expect(candidates == AddFolderCandidates(folders: ["/docs"], projects: ["/other"]))
    }

    @Test func aProjectAlsoRecentlyLinkedShowsOnlyAsAFolder() {
        let candidates = AddFolderCandidates(
            recentFolders: ["/shared"],
            recentProjects: ["/shared", "/other", "/other"],
            linked: [],
            workingDirectory: nil
        )
        #expect(candidates == AddFolderCandidates(folders: ["/shared"], projects: ["/other"]))
    }
}
