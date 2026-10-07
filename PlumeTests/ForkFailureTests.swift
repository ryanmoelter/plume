import Foundation
import Testing
@testable import Plume

/// How a refused fork is reported.
///
/// `--resume-session-at` is undocumented, so a CLI upgrade can withdraw it
/// without warning. The stderr lines here were captured from a real `claude`
/// 2.1.280, not invented: both failure modes exit 1 with one stderr line and
/// no stdout, which on its own is indistinguishable from any other dead
/// launch.
struct ForkFailureTests {
    private static let withdrawnFlag = "error: unknown option '--resume-session-at'"
    private static let missingTarget =
        "No message found with message.uuid of: deadbeef-0000-0000-0000-000000000000"

    @Test func aWithdrawnFlagIsReportedAsForkingBeingUnavailable() {
        let failure = ChatStartFailure.forkRefusal(error: Self.withdrawnFlag)
        #expect(failure == ChatStartFailure.forkUnavailable(detail: Self.withdrawnFlag))
    }

    @Test func aCutPointTheSessionDoesNotContainIsReportedSeparately() {
        let failure = ChatStartFailure.forkRefusal(error: Self.missingTarget)
        #expect(failure == ChatStartFailure.forkTargetMissing(detail: Self.missingTarget))
    }

    /// The point of routing these separately: the generic classification
    /// offers a retry, which for a refused fork can only fail the same way.
    @Test func theGenericClassificationWouldOfferAFutileRetry() throws {
        let generic = try #require(
            ChatStartFailure.classify(error: Self.withdrawnFlag, exitStatus: 1)
        )
        #expect(generic.remedy == .retry)
    }

    /// A line neither known mode matches still has to reach `.redoInstead`.
    /// The fork tab records a session id the CLI never wrote, so the retry
    /// the generic classification offers resumes a conversation that does not
    /// exist and fails again with different wording.
    @Test(arguments: [
        "zsh: command not found: claude",
        "error: unknown option '--verbose'",
        "",
    ])
    func anUnrecognizedFailureStillDeclinesToOfferARetry(line: String) {
        #expect(ChatStartFailure.forkRefusal(error: line).remedy == .redoInstead)
    }

    @Test func aForkThatDiedWithNoStderrIsStillReportedAsAFork() {
        #expect(ChatStartFailure.forkRefusal(error: nil) == ChatStartFailure.forkFailed(detail: nil))
    }

    /// The specific modes must not be claimed by an unrelated line: a
    /// different option going missing is not `--resume-session-at` going
    /// missing.
    @Test func anotherUnknownOptionIsNotTheWithdrawnFlag() {
        let failure = ChatStartFailure.forkRefusal(error: "error: unknown option '--verbose'")
        #expect(failure != ChatStartFailure.forkUnavailable(detail: "error: unknown option '--verbose'"))
    }
}
