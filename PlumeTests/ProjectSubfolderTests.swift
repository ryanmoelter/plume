import Foundation
import Testing
@testable import Plume

/// Splitting a chosen path into its project checkout and the subfolder
/// beneath it.
struct ProjectSubfolderTests {
    private let project = CheckoutFacts(projectRoot: "/repos/notability", checkoutRoot: "/repos/notability")
    private let worktree = CheckoutFacts(
        projectRoot: "/repos/notability",
        checkoutRoot: "/repos/notability/.plume/worktrees/fix"
    )

    @Test func pathInsideAProjectIsASubfolder() {
        let split = ProjectSubfolder.split(path: "/repos/notability/Android/app", facts: project)
        #expect(split?.projectRoot == "/repos/notability")
        #expect(split?.subfolder == "Android/app")
    }

    @Test func projectRootHasNoSubfolder() {
        let split = ProjectSubfolder.split(path: "/repos/notability/", facts: project)
        #expect(split?.projectRoot == "/repos/notability")
        #expect(split?.subfolder == nil)
    }

    @Test func pathOutsideEveryProjectHasNoSplit() {
        #expect(ProjectSubfolder.split(path: "/tmp/scratch", facts: nil) == nil)
        #expect(ProjectSubfolder.split(path: "/repos/other/Android", facts: project) == nil)
        #expect(ProjectSubfolder.split(path: "/repos/notability-docs", facts: project) == nil)
    }

    @Test func worktreePathSplitsAgainstItsOwnCheckout() {
        let split = ProjectSubfolder.split(
            path: "/repos/notability/.plume/worktrees/fix/Android",
            facts: worktree
        )
        #expect(split?.projectRoot == "/repos/notability")
        #expect(split?.checkoutRoot == "/repos/notability/.plume/worktrees/fix")
        #expect(split?.subfolder == "Android")
    }

    @Test func relativePathIsEmptyAtTheCheckoutAndNilOutsideIt() {
        #expect(ProjectSubfolder.relativePath(of: "/a/b/c", in: "/a/b") == "c")
        #expect(ProjectSubfolder.relativePath(of: "/a/b/", in: "/a/b") == "")
        #expect(ProjectSubfolder.relativePath(of: "/a/bc", in: "/a/b") == nil)
    }

    @Test func existingDirectoryFallsBackToTheCheckout() {
        #expect(ProjectSubfolder.existingDirectory(checkoutRoot: "/a", subfolder: "b", isDirectory: { _ in true }) == "/a/b")
        #expect(ProjectSubfolder.existingDirectory(checkoutRoot: "/a", subfolder: "b", isDirectory: { _ in false }) == "/a")
    }

    @Test func directoryJoinsSubfolderOntoCheckout() {
        #expect(ProjectSubfolder.directory(checkoutRoot: "/a/b", subfolder: "c/d") == "/a/b/c/d")
        #expect(ProjectSubfolder.directory(checkoutRoot: "/a/b", subfolder: nil) == "/a/b")
    }
}
