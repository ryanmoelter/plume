import Testing
@testable import Plume

struct ReviewBaseTests {
    private let branches: StackBranches = [
        "root": StackEntry(parent: "main", base: "a"),
        "middle": StackEntry(parent: "root", base: "b"),
    ]

    @Test func onlyATrackedParentIsAStackParent() {
        #expect(ReviewBaseOptions.stackParent(of: "middle", in: branches) == "refs/heads/root")
        #expect(ReviewBaseOptions.stackParent(of: "root", in: branches) == nil)
        #expect(ReviewBaseOptions.stackParent(of: "untracked", in: branches) == nil)
    }

    @Test func aPickNoLongerOfferedFallsBackToTheDefault() {
        let options = ReviewBaseOptions(
            stackParent: nil,
            originDefault: .init(ref: "refs/remotes/origin/main"),
            upstream: nil,
            hasPreviousCommit: false
        )
        #expect(options.available == [.originDefault, .head])
        #expect(ReviewModel.effectiveBase(chosen: .upstream, options: options) == .originDefault)
        #expect(ReviewModel.effectiveBase(chosen: .head, options: options) == .head)
        #expect(options.watchedRef(for: .head) == nil)
        #expect(options.watchedRef(for: .originDefault) == "refs/remotes/origin/main")
    }
}
