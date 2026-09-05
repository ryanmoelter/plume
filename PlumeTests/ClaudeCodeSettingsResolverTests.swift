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

    private func resolvedModel(shared: String?, local: String? = nil) -> AgentModel? {
        ClaudeCodeSettingsResolver.resolvedDefaultModel(
            settingsPath: writeFixture(shared),
            localSettingsPath: writeFixture(local)
        )
    }

    @Test func resolvesTheConfiguredModelAlias() {
        #expect(resolvedModel(shared: #"{ "model": "sonnet" }"#) == .sonnet)
    }

    /// The context-window suffix names a variant of the same model.
    @Test func resolvesAnAliasCarryingAContextSuffix() {
        #expect(resolvedModel(shared: #"{ "model": "opus[1m]" }"#) == .opus)
    }

    @Test func resolvesAFullModelID() {
        #expect(resolvedModel(shared: #"{ "model": "claude-opus-5" }"#) == .opus)
    }

    @Test func theLocalFileOverridesTheSharedOne() {
        let model = resolvedModel(
            shared: #"{ "model": "sonnet" }"#,
            local: #"{ "model": "opus" }"#
        )
        #expect(model == .opus)
    }

    /// A local file that configures no model leaves the shared one standing.
    @Test func theSharedFileStandsWhenTheLocalOneOmitsTheKey() {
        #expect(resolvedModel(shared: #"{ "model": "sonnet" }"#, local: "{}") == .sonnet)
    }

    @Test func missingModelKeyResolvesToNil() {
        #expect(resolvedModel(shared: "{}") == nil)
    }

    @Test func unrecognizedModelResolvesToNil() {
        #expect(resolvedModel(shared: #"{ "model": "gpt-9" }"#) == nil)
    }

    @Test func missingFilesResolveTheModelToNil() {
        #expect(resolvedModel(shared: nil) == nil)
    }
}
