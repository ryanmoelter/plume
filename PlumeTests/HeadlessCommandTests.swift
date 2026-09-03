import Testing
import Foundation
@testable import Plume

struct HeadlessCommandTests {
    private func permissionModeToken(in arguments: [String]) -> String? {
        guard let flagIndex = arguments.firstIndex(of: "--permission-mode") else { return nil }
        let tokenIndex = arguments.index(after: flagIndex)
        return arguments.indices.contains(tokenIndex) ? arguments[tokenIndex] : nil
    }

    @Test func passesPlanWhenResolvedToPlan() {
        let arguments = HeadlessCommand.arguments(
            resumeSessionID: nil,
            permissionMode: .plan,
            settingsPath: nil
        )
        #expect(permissionModeToken(in: arguments) == "plan")
    }

    @Test func passesAcceptEditsWhenResolvedToAcceptEdits() {
        let arguments = HeadlessCommand.arguments(
            resumeSessionID: nil,
            permissionMode: .acceptEdits,
            settingsPath: nil
        )
        #expect(permissionModeToken(in: arguments) == "acceptEdits")
    }

    @Test func passesAutoWhenResolvedToAuto() {
        let arguments = HeadlessCommand.arguments(
            resumeSessionID: nil,
            permissionMode: .auto,
            settingsPath: nil
        )
        #expect(permissionModeToken(in: arguments) == "auto")
    }

    @Test func passesBypassPermissionsWhenResolvedToBypassPermissions() {
        let arguments = HeadlessCommand.arguments(
            resumeSessionID: nil,
            permissionMode: .bypassPermissions,
            settingsPath: nil
        )
        #expect(permissionModeToken(in: arguments) == "bypassPermissions")
    }

    /// `.acceptEdits` is the floor when resolution comes back with nothing —
    /// not Plume's preferred mode, just what keeps a `-p` session out of
    /// Manual.
    @Test func fallsBackToAcceptEditsWhenResolutionIsNil() {
        let arguments = HeadlessCommand.arguments(
            resumeSessionID: nil,
            permissionMode: nil,
            settingsPath: nil
        )
        #expect(permissionModeToken(in: arguments) == "acceptEdits")
    }
}
