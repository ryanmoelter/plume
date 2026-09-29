import Testing
@testable import Plume

struct ClaudeModelDefaultTests {
    @Test(arguments: [
        ClaudeModelDefault.followClaudeCode,
        .model(.opus),
        .model(.fable),
        .model(.opus5dot5),
        .model(.haiku4dot5At200K),
    ])
    func rawValueRoundTrips(value: ClaudeModelDefault) {
        #expect(ClaudeModelDefault(rawValue: value.rawValue) == value)
    }

    @Test func followingPinsNoModel() {
        #expect(ClaudeModelDefault.followClaudeCode.pinnedModel == nil)
        #expect(ClaudeModelDefault.model(.sonnet).pinnedModel == .sonnet)
    }

    /// A model ID from a newer build still pins rather than falling back to
    /// following the CLI.
    @Test func anUnknownIDStillPins() {
        #expect(ClaudeModelDefault(rawValue: "claude-newthing-9").pinnedModel?.id == "claude-newthing-9")
    }

    @Test func anEmptyRawValueFollowsClaudeCode() {
        #expect(ClaudeModelDefault(rawValue: "") == .followClaudeCode)
    }

    @Test func offeredLeadsWithFollowThenEveryPreset() {
        let offered = ClaudeModelDefault.offered(including: .followClaudeCode)
        #expect(offered.first == .followClaudeCode)
        #expect(offered.dropFirst().compactMap(\.pinnedModel) == AgentModel.selectable)
    }

    @Test func offeredKeepsAStoredModelOutsideThePresets() {
        let unknown = ClaudeModelDefault.model(AgentModel(unrecognizedID: "claude-newthing-9"))
        #expect(ClaudeModelDefault.offered(including: unknown).last == unknown)
    }
}
