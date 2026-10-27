import Foundation
import Testing
@testable import Plume

/// `submit` and `sync` fail with the forge CLI's own problem before they
/// touch git.
struct StackForgeReadinessTests {
    private func notReadyForge() -> RecordingStackForge {
        let forge = RecordingStackForge([:])
        forge.notReady = CLIFailure("gh is not authenticated — run `gh auth login`")
        return forge
    }

    @Test func submitStopsOnAForgeThatIsNotReady() throws {
        let repo = try StackScratchRepo()

        let failure = stackFailure { try Stack.submit(repo.context(forge: notReadyForge()), []) }

        #expect(failure?.message == "gh is not authenticated — run `gh auth login`")
    }

    @Test func syncStopsOnAForgeThatIsNotReadyBeforeFetching() throws {
        let repo = try StackScratchRepo()
        try repo.git("remote", "set-url", "origin", "\(repo.directory)/missing.git")

        let failure = stackFailure { try Stack.sync(repo.context(forge: notReadyForge()), []) }

        #expect(failure?.message == "gh is not authenticated — run `gh auth login`")
    }
}
