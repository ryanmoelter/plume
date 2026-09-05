import Testing
@testable import Plume

struct ModelEffortCommandTests {
    @Test(arguments: [
        (AgentModel.fable, "/model claude-fable-5-1"),
        (AgentModel.opus, "/model claude-opus-5[1m]"),
        (AgentModel.sonnet, "/model claude-sonnet-5[1m]"),
    ])
    func setModelBuildsExactCommand(model: AgentModel, expected: String) {
        #expect(ModelEffortCommand.setModel(model) == expected)
    }

    @Test(arguments: [
        (AgentEffort.low, "/effort low"),
        (AgentEffort.medium, "/effort medium"),
        (AgentEffort.high, "/effort high"),
        (AgentEffort.xhigh, "/effort xhigh"),
        (AgentEffort.max, "/effort max"),
    ])
    func setEffortBuildsExactCommand(effort: AgentEffort, expected: String) {
        #expect(ModelEffortCommand.setEffort(effort) == expected)
    }

    @Test
    func sanitizedTokenAcceptsAPlainToken() throws {
        #expect(try ModelEffortCommand.sanitizedToken("sonnet") == "sonnet")
    }

    @Test(arguments: [
        "sonnet extra",
        "sonnet\n",
        "sonnet\r\n/rm -rf",
        " sonnet",
        "son\tnet",
    ])
    func sanitizedTokenRejectsWhitespaceOrNewlines(token: String) {
        #expect(throws: ModelEffortCommand.InvalidTokenError.self) {
            try ModelEffortCommand.sanitizedToken(token)
        }
    }

    /// The top-level menu offers 1M context where it exists, so the bare
    /// aliases must keep landing on the 256K models they actually resolve to
    /// — see "Model aliases" in docs/headless-protocol.md.
    @Test(arguments: [
        ("claude-opus-5", "claude-opus-5"),
        ("opus", "claude-opus-5"),
        ("sonnet", "claude-sonnet-5"),
        ("haiku", "claude-haiku-4-5-20251001"),
    ])
    func recognizingMapsAnAliasToItsPlainModel(reported: String, expectedID: String) {
        #expect(AgentModel.recognizing(reported)?.id == expectedID)
    }

    /// A `[1m]` suffix names the 1M variant, which is a different model to
    /// pass to `--model`, not a decoration to strip.
    @Test(arguments: [
        ("claude-opus-5[1m]", AgentModel.opus),
        ("opus[1m]", AgentModel.opus),
        ("sonnet[1m]", AgentModel.sonnet),
    ])
    func recognizingPromotesAContextSuffixToTheOneMillionVariant(
        reported: String,
        expected: AgentModel
    ) {
        #expect(AgentModel.recognizing(reported) == expected)
    }

    /// Fable takes the suffix but reports back plain, so there is nothing to
    /// promote it to.
    @Test func fableHasNoDistinctOneMillionVariant() {
        #expect(AgentModel.recognizing("fable[1m]") == .fable)
        #expect(AgentModel.fable.id == "claude-fable-5-1")
    }

    /// The CLI echoes back whatever ID it was given, including one this build
    /// has never heard of, so an unknown ID has to survive rather than vanish.
    @Test func recognizingRoundTripsAnUnknownID() throws {
        let model = try #require(AgentModel.recognizing("claude-newthing-9"))
        #expect(model.id == "claude-newthing-9")
        #expect(model.label == "newthing-9")
        #expect(AgentModel.recognizing(model.id) == model)
    }

    @Test func recognizingReturnsNilOnlyForAnEmptyString() {
        #expect(AgentModel.recognizing("") == nil)
        #expect(AgentModel.recognizing("   ") == nil)
    }

    /// A captured statusline payload reports a display name rather than the
    /// transcript's model ID.
    @Test(arguments: [
        ("Opus 5", "claude-opus-5"),
        ("Sonnet 5", "claude-sonnet-5"),
        ("Fable 5", "claude-fable-5-1"),
    ])
    func recognizingMapsDisplayNames(reported: String, expectedID: String) {
        #expect(AgentModel.recognizing(reported)?.id == expectedID)
    }

    @Test(arguments: [
        ("low", AgentEffort.low),
        ("medium", AgentEffort.medium),
        ("high", AgentEffort.high),
        ("xhigh", AgentEffort.xhigh),
        ("max", AgentEffort.max),
    ])
    func recognizingRoundTripsAllEffortLevels(reported: String, expected: AgentEffort) {
        #expect(AgentEffort.recognizing(reported) == expected)
    }

    @Test
    func recognizingReturnsNilForAnUnrecognizedEffortString() {
        #expect(AgentEffort.recognizing("ultra") == nil)
    }
}
