import Testing
import Foundation
@testable import Plume

struct CheckoutFactsTests {
    /// In the original clone, `--git-common-dir` is its own `.git`.
    @Test func theMainCheckoutIsNotAWorktree() throws {
        let facts = try #require(CheckoutFacts.parsing("/repo/.git\n/repo"))
        #expect(facts.projectRoot == "/repo")
        #expect(facts.checkoutRoot == "/repo")
        #expect(facts.isWorktree == false)
        #expect(facts.projectName == "repo")
    }

    /// The common dir still points at the original clone, which is what lets
    /// one call answer both questions.
    @Test func aLinkedWorktreeReportsTheProjectItBelongsTo() throws {
        let facts = try #require(CheckoutFacts.parsing("/repo/.git\n/elsewhere/feature"))
        #expect(facts.projectRoot == "/repo")
        #expect(facts.checkoutRoot == "/elsewhere/feature")
        #expect(facts.isWorktree)
        #expect(facts.projectName == "repo")
    }

    /// Two worktrees of one repository must read as the same project, which is
    /// the whole reason the header stopped using the folder name.
    @Test func twoWorktreesShareOneProjectName() throws {
        let one = try #require(CheckoutFacts.parsing("/repo/.git\n/wt/a"))
        let other = try #require(CheckoutFacts.parsing("/repo/.git\n/wt/b"))
        #expect(one.projectName == other.projectName)
    }

    @Test func trailingSlashesDoNotMakeACheckoutLookLikeAWorktree() throws {
        let facts = try #require(CheckoutFacts.parsing("/repo/.git/\n/repo/"))
        #expect(facts.isWorktree == false)
    }

    @Test func aBareRepositoryWithNoToplevelYieldsNothing() {
        #expect(CheckoutFacts.parsing("/repo.git") == nil)
        #expect(CheckoutFacts.parsing("") == nil)
    }
}
