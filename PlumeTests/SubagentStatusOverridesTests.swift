import Testing
import Foundation
@testable import Plume

/// The manual escape hatch for a subagent nothing can settle on its own.
///
/// The override is applied after derivation and only ever replaces `working`,
/// so marking a row can never contradict a subagent that reported for itself.
@MainActor
struct SubagentStatusOverridesTests {
    private func store() -> SubagentStatusOverrides {
        let defaults = UserDefaults(suiteName: "SubagentStatusOverridesTests-\(UUID().uuidString)")!
        return SubagentStatusOverrides(defaults: defaults)
    }

    private func subagent(id: String = "a1", status: TaskStatus) -> SubagentTranscript {
        SubagentTranscript(id: id, transcript: Transcript(), modifiedAt: nil, status: status)
    }

    @Test func anOverrideReplacesAWorkingStatus() {
        let overrides = store()
        let tabID = UUID()
        overrides.set(.done, tabID: tabID, subagentID: "a1")

        let applied = overrides.applying([subagent(status: .working)], tabID: tabID)

        #expect(applied.first?.status == .done)
    }

    @Test func markingARowInterruptedSettlesIt() {
        let overrides = store()
        let tabID = UUID()
        overrides.set(.interrupted, tabID: tabID, subagentID: "a1")

        #expect(overrides.applying([subagent(status: .working)], tabID: tabID).first?.status == .interrupted)
    }

    /// The constraint that makes this safe: a subagent that reports for itself
    /// outranks anything the user marked earlier.
    @Test(arguments: [TaskStatus.done, .error, .questionAsked, .interrupted])
    func anOverrideNeverReplacesAStatusTheTranscriptStated(status: TaskStatus) {
        let overrides = store()
        let tabID = UUID()
        overrides.set(.done, tabID: tabID, subagentID: "a1")

        #expect(overrides.applying([subagent(status: status)], tabID: tabID).first?.status == status)
    }

    @Test func anOverrideAppliesOnlyToTheRowItNames() {
        let overrides = store()
        let tabID = UUID()
        overrides.set(.done, tabID: tabID, subagentID: "a1")

        let applied = overrides.applying(
            [subagent(id: "a1", status: .working), subagent(id: "a2", status: .working)],
            tabID: tabID
        )

        #expect(applied.first?.status == .done)
        #expect(applied.last?.status == .working)
    }

    /// Two tabs can hold subagents with the same id, so the key has to carry
    /// both halves.
    @Test func anOverrideAppliesOnlyToTheTabItNames() {
        let overrides = store()
        let tabID = UUID()
        overrides.set(.done, tabID: tabID, subagentID: "a1")

        #expect(overrides.applying([subagent(status: .working)], tabID: UUID()).first?.status == .working)
    }

    @Test func clearingAnOverrideRestoresTheDerivedStatus() {
        let overrides = store()
        let tabID = UUID()
        overrides.set(.done, tabID: tabID, subagentID: "a1")
        overrides.set(nil, tabID: tabID, subagentID: "a1")

        #expect(overrides.override(tabID: tabID, subagentID: "a1") == nil)
        #expect(overrides.applying([subagent(status: .working)], tabID: tabID).first?.status == .working)
    }

    /// The point of dismissing a stuck row is that it stays dismissed, so the
    /// override has to survive a relaunch.
    @Test func anOverrideSurvivesARelaunch() {
        let defaults = UserDefaults(suiteName: "SubagentStatusOverridesTests-\(UUID().uuidString)")!
        let tabID = UUID()
        SubagentStatusOverrides(defaults: defaults).set(.interrupted, tabID: tabID, subagentID: "a1")

        let reloaded = SubagentStatusOverrides(defaults: defaults)

        #expect(reloaded.override(tabID: tabID, subagentID: "a1") == .interrupted)
    }

    @Test func forgettingATabDropsOnlyItsOverrides() {
        let overrides = store()
        let kept = UUID()
        let dropped = UUID()
        overrides.set(.done, tabID: kept, subagentID: "a1")
        overrides.set(.done, tabID: dropped, subagentID: "a1")

        overrides.forget(tabID: dropped)

        #expect(overrides.override(tabID: kept, subagentID: "a1") == .done)
        #expect(overrides.override(tabID: dropped, subagentID: "a1") == nil)
    }
}
