import Testing
import Foundation
@testable import Plume

struct ClaudeCodeSettingsResolverTests {
    private func writeFixture(_ contents: String?) -> String {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeCodeSettingsResolverTests-\(UUID().uuidString).json")
            .path
        if let contents {
            try? contents.write(toFile: path, atomically: true, encoding: .utf8)
        }
        return path
    }

    @Test func resolvesTheConfiguredMode() {
        let path = writeFixture("""
        { "permissions": { "defaultMode": "plan" } }
        """)
        #expect(ClaudeCodeSettingsResolver.resolvedDefaultPermissionMode(settingsPath: path) == .plan)
    }

    @Test func missingFileResolvesToNil() {
        let path = writeFixture(nil)
        #expect(ClaudeCodeSettingsResolver.resolvedDefaultPermissionMode(settingsPath: path) == nil)
    }

    @Test func malformedJSONResolvesToNil() {
        let path = writeFixture("{ not valid json")
        #expect(ClaudeCodeSettingsResolver.resolvedDefaultPermissionMode(settingsPath: path) == nil)
    }

    @Test func missingKeyResolvesToNil() {
        let path = writeFixture("""
        { "permissions": { "allow": [] } }
        """)
        #expect(ClaudeCodeSettingsResolver.resolvedDefaultPermissionMode(settingsPath: path) == nil)
    }

    @Test func unrecognizedModeResolvesToNil() {
        let path = writeFixture("""
        { "permissions": { "defaultMode": "manual" } }
        """)
        #expect(ClaudeCodeSettingsResolver.resolvedDefaultPermissionMode(settingsPath: path) == nil)
    }
}
