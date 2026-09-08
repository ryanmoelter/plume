import Testing
@testable import Plume

/// The fold `wt list` shows in its checks column. Statuses are the ones
/// GitHub's rollup really emits.
struct CheckRollupTests {
    private func contexts(_ pairs: [(String, String)]) -> [CheckContext] {
        pairs.map { CheckContext(name: $0.0, status: $0.1) }
    }

    @Test func noChecksAtAllIsNoneNotPending() {
        #expect(CheckRollup.folding([]) == .none)
    }

    @Test func allSuccessIsSuccess() {
        #expect(CheckRollup.folding(contexts([("build", "SUCCESS"), ("lint", "SUCCESS")])) == .success)
    }

    @Test func anyPendingBeatsSuccess() {
        #expect(CheckRollup.folding(contexts([("build", "SUCCESS"), ("lint", "PENDING")])) == .pending)
    }

    @Test func anyFailureBeatsPending() {
        let fold = CheckRollup.folding(contexts([("build", "FAILURE"), ("lint", "PENDING")]))
        #expect(fold == .failure)
    }

    @Test(arguments: ["FAILURE", "ERROR", "TIMED_OUT", "ACTION_REQUIRED"])
    func everyFailingStatusFails(_ status: String) {
        #expect(CheckRollup.folding(contexts([("build", status)])) == .failure)
    }

    @Test(arguments: ["NEUTRAL", "SKIPPED", "CANCELLED"])
    func inertStatusesDoNotBlock(_ status: String) {
        #expect(CheckRollup.folding(contexts([("build", "SUCCESS"), ("aux", status)])) == .success)
    }

    @Test func statusIsMatchedCaseInsensitively() {
        #expect(CheckRollup.folding(contexts([("build", "success")])) == .success)
    }

    // MARK: - The ignore list

    @Test func anIgnoredChecksPendingIsSuppressed() {
        let fold = CheckRollup.folding(
            contexts([("build", "SUCCESS"), ("flaky", "PENDING")]),
            ignoredWhenPending: ["flaky"]
        )
        #expect(fold == .success)
    }

    @Test func anIgnoredChecksFailureStillFails() {
        let fold = CheckRollup.folding(
            contexts([("build", "SUCCESS"), ("flaky", "FAILURE")]),
            ignoredWhenPending: ["flaky"]
        )
        #expect(fold == .failure)
    }

    @Test func anIgnoredCheckAloneAndPendingIsSuccessNotNone() {
        // Checks exist, so the answer is not `.none`; the only unsettled one
        // is ignored, so nothing is left to wait on.
        let fold = CheckRollup.folding(
            contexts([("flaky", "PENDING")]),
            ignoredWhenPending: ["flaky"]
        )
        #expect(fold == .success)
    }

    @Test func ignoringOneCheckLeavesAnotherPending() {
        let fold = CheckRollup.folding(
            contexts([("flaky", "PENDING"), ("build", "IN_PROGRESS")]),
            ignoredWhenPending: ["flaky"]
        )
        #expect(fold == .pending)
    }

    // MARK: - Status source fallback

    @Test func aCheckRunUsesItsConclusion() {
        let flattened = CheckContext(name: "build", conclusion: "SUCCESS", status: "COMPLETED")
        #expect(flattened == CheckContext(name: "build", status: "SUCCESS"))
    }

    @Test func anInProgressCheckRunFallsBackToItsStatus() {
        let flattened = CheckContext(name: "build", conclusion: nil, status: "IN_PROGRESS")
        #expect(flattened.status == "IN_PROGRESS")
        #expect(CheckRollup.folding([flattened]) == .pending)
    }

    @Test func aStatusContextUsesItsContextAndState() {
        let flattened = CheckContext(context: "ci/circleci: lint", state: "PENDING")
        #expect(flattened.name == "ci/circleci: lint")
        #expect(flattened.status == "PENDING")
    }

    @Test func aContextWithNoStatusAtAllReadsAsPending() {
        #expect(CheckRollup.folding([CheckContext(name: "mystery")]) == .pending)
    }
}
