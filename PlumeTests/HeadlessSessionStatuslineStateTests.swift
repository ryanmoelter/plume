import Foundation
import Testing
@testable import Plume

/// Covers the optimistic-then-corrected state `HeadlessSession` tracks for
/// permission mode, model and effort — the display source the statusline
/// strip and the composer's controls row read instead of the transcript.
@MainActor
struct HeadlessSessionStatuslineStateTests {
    private func makeSession() -> HeadlessSession {
        HeadlessSession(tabID: UUID(), taskID: UUID())
    }

    private func sessionInit(model: String? = nil, permissionMode: String? = nil) -> SessionInit {
        SessionInit(
            sessionID: "session-1",
            cwd: nil,
            model: model,
            permissionMode: permissionMode,
            tools: [],
            slashCommands: []
        )
    }

    @Test func setPermissionModeIsOptimistic() {
        let session = makeSession()
        #expect(session.permissionMode == nil)

        session.setPermissionMode(.acceptEdits)

        #expect(session.permissionMode == .acceptEdits)
    }

    @Test func setModelIsOptimistic() {
        let session = makeSession()
        #expect(session.model == nil)

        session.setModel(.opus)

        #expect(session.model == .opus)
    }

    @Test func setEffortIsOptimisticAndNeverCorrected() {
        let session = makeSession()

        session.setEffort(.high)

        #expect(session.effort == .high)

        // No stream event carries effort back, so nothing should clear or
        // change it — unlike model/permissionMode below.
        session.handle(.initialized(sessionInit(model: "sonnet", permissionMode: "plan")))

        #expect(session.effort == .high)
    }

    @Test func initializedCorrectsAnOptimisticModelToWhatTheStreamReports() {
        let session = makeSession()
        session.setModel(.sonnet)

        session.handle(.initialized(sessionInit(model: "claude-opus-5")))

        #expect(session.model == .opus)
    }

    @Test func initializedCorrectsAnOptimisticPermissionModeToWhatTheStreamReports() {
        let session = makeSession()
        session.setPermissionMode(.plan)

        session.handle(.initialized(sessionInit(permissionMode: "bypassPermissions")))

        #expect(session.permissionMode == .bypassPermissions)
    }

    @Test func initializedLeavesModelUnchangedWhenUnrecognized() {
        let session = makeSession()
        session.setModel(.sonnet)

        session.handle(.initialized(sessionInit(model: "some-future-model")))

        #expect(session.model == .sonnet)
    }

    @Test func initializedLeavesPermissionModeUnchangedWhenUnrecognized() {
        let session = makeSession()
        session.setPermissionMode(.auto)

        // "manual" is a real CLI mode PermissionMode deliberately doesn't
        // offer (see PermissionMode's doc comment).
        session.handle(.initialized(sessionInit(permissionMode: "manual")))

        #expect(session.permissionMode == .auto)
    }

    @Test func initializedSeedsPermissionModeWhenNoneWasSetYet() {
        let session = makeSession()

        session.handle(.initialized(sessionInit(permissionMode: "acceptEdits")))

        #expect(session.permissionMode == .acceptEdits)
    }

    /// Allowing `ExitPlanMode` only answers that tool call — the CLI has no
    /// field on the response for changing mode, so approving a plan without
    /// also switching mode leaves the session stuck in `plan` and the agent
    /// never starts work. `approvePlan` must switch mode alongside allowing.
    @Test func approvingAPlanSwitchesOutOfPlanMode() {
        let session = makeSession()
        session.setPermissionMode(.plan)
        let permission = PendingPermission(
            id: "req-1",
            toolName: "ExitPlanMode",
            displayName: "ExitPlanMode",
            input: ["plan": .string("Do the thing")],
            description: nil,
            decisionReason: nil,
            toolUseID: "toolu_1",
            agentID: nil,
            interactive: .plan(markdown: "Do the thing", filePath: nil)
        )

        session.approvePlan(permission)

        #expect(session.permissionMode == .auto)
    }
}
