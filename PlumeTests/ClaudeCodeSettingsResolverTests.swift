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
        { "permissions": { "defaultMode": "dontAsk" } }
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
        #expect(resolvedModel(shared: #"{ "model": "sonnet" }"#)?.id == "claude-sonnet-5")
    }

    /// `opus[1m]` is exactly the top-level alias Plume's own picker sends, so
    /// a `~/.claude/settings.json` configuring it resolves to that same
    /// entry — shown as "Opus" until a session reports the resolved version.
    @Test func resolvesAnAliasCarryingAContextSuffix() {
        #expect(resolvedModel(shared: #"{ "model": "opus[1m]" }"#) == .opus)
        #expect(AgentModel.opus.label == "Opus")
    }

    @Test func resolvesAFullModelID() {
        #expect(resolvedModel(shared: #"{ "model": "claude-opus-5" }"#)?.id == "claude-opus-5")
    }

    @Test func theLocalFileOverridesTheSharedOne() {
        let model = resolvedModel(
            shared: #"{ "model": "sonnet" }"#,
            local: #"{ "model": "opus" }"#
        )
        #expect(model?.id == "claude-opus-5-5")
    }

    /// A local file that configures no model leaves the shared one standing.
    @Test func theSharedFileStandsWhenTheLocalOneOmitsTheKey() {
        #expect(resolvedModel(shared: #"{ "model": "sonnet" }"#, local: "{}")?.id == "claude-sonnet-5")
    }

    @Test func missingModelKeyResolvesToNil() {
        #expect(resolvedModel(shared: "{}") == nil)
    }

    /// A model this build has no preset for is still what the CLI will launch
    /// on, so it resolves to itself rather than being discarded.
    @Test func anUnfamiliarModelResolvesToItsOwnID() {
        #expect(resolvedModel(shared: #"{ "model": "claude-next-7" }"#)?.id == "claude-next-7")
    }

    @Test func missingFilesResolveTheModelToNil() {
        #expect(resolvedModel(shared: nil) == nil)
    }
}
