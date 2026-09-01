import Testing
@testable import Plume

struct AgentAutoResumeTests {
    @Test func resumesWhenSessionStoredDirectoryExistsAndNoLiveSession() {
        #expect(AgentAutoResume.shouldResume(
            agentSessionID: "abc123",
            workingDirectoryPath: "/tmp/some-task",
            hasExistingSurfaceSession: false,
            directoryExists: { _ in true }
        ) == true)
    }

    @Test func doesNotResumeWhenDirectoryMissing() {
        #expect(AgentAutoResume.shouldResume(
            agentSessionID: "abc123",
            workingDirectoryPath: "/tmp/gone",
            hasExistingSurfaceSession: false,
            directoryExists: { _ in false }
        ) == false)
    }

    @Test func doesNotResumeWhenSurfaceSessionAlreadyExists() {
        #expect(AgentAutoResume.shouldResume(
            agentSessionID: "abc123",
            workingDirectoryPath: "/tmp/some-task",
            hasExistingSurfaceSession: true,
            directoryExists: { _ in true }
        ) == false)
    }

    @Test func doesNotResumeWithNoStoredSession() {
        #expect(AgentAutoResume.shouldResume(
            agentSessionID: nil,
            workingDirectoryPath: "/tmp/some-task",
            hasExistingSurfaceSession: false,
            directoryExists: { _ in true }
        ) == false)
    }

    @Test func doesNotResumeWithEmptyStoredSessionID() {
        #expect(AgentAutoResume.shouldResume(
            agentSessionID: "",
            workingDirectoryPath: "/tmp/some-task",
            hasExistingSurfaceSession: false,
            directoryExists: { _ in true }
        ) == false)
    }

    @Test func doesNotResumeWithNoWorkingDirectory() {
        #expect(AgentAutoResume.shouldResume(
            agentSessionID: "abc123",
            workingDirectoryPath: nil,
            hasExistingSurfaceSession: false,
            directoryExists: { _ in true }
        ) == false)
    }
}
