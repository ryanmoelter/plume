import Testing
@testable import Plume

struct ModelEffortCommandTests {
    @Test(arguments: [
        (AgentModel.fable, "/model claude-fable-5-1"),
        (AgentModel.opus, "/model claude-opus-5-5[1m]"),
        (AgentModel.sonnet, "/model claude-sonnet-5[1m]"),
        (AgentModel.haiku, "/model claude-haiku-4-5-20251001[1m]"),
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

    /// A bracketed 1M ID is a plain token as far as the terminal is concerned
    /// — only whitespace could inject a second line.
    @Test func setModelKeepsTheContextSuffix() {
        #expect(ModelEffortCommand.setModel(.opus) == "/model claude-opus-5-5[1m]")
    }

    /// A model ID carrying a newline must not reach the terminal as a command
    /// with a second line after it.
    @Test func setModelRefusesAnIDThatWouldInjectALine() {
        let injected = AgentModel(unrecognizedID: "opus\n/rm -rf")
        #expect(ModelEffortCommand.setModel(injected) == "/model")
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
    /// aliases must keep landing on the 200K models they actually resolve to
    /// — see "Model aliases" in docs/headless-protocol.md.
    @Test(arguments: [
        ("claude-opus-5-5", "claude-opus-5-5"),
        ("opus", "claude-opus-5-5"),
        ("opus 5.5", "claude-opus-5-5"),
        ("opus 5", "claude-opus-5"),
        ("sonnet", "claude-sonnet-5"),
        ("haiku", "claude-haiku-4-5-20251001"),
    ])
    func recognizingMapsAnAliasToItsPlainModel(reported: String, expectedID: String) {
        #expect(AgentModel.recognizing(reported)?.id == expectedID)
    }

    /// A `[1m]` suffix names the 1M variant, which is a different model to
    /// pass to `--model`, not a decoration to strip.
    @Test(arguments: [
        ("claude-opus-5-5[1m]", AgentModel.opus),
        ("opus[1m]", AgentModel.opus),
        ("sonnet[1m]", AgentModel.sonnet),
        ("haiku[1m]", AgentModel.haiku),
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
        #expect(model.label == "Newthing 9")
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

    // MARK: - ModelDisplayName

    @Test(arguments: [
        ("opus-5-5[1m]", "Opus 5.5"),
        ("claude-opus-5-5[1m]", "Opus 5.5"),
        ("claude-haiku-4-5-20251001", "Haiku 4.5"),
        ("claude-sonnet-6-1", "Sonnet 6.1"),
        ("claude-sonnet-5", "Sonnet 5"),
        ("claude-fable-5-1", "Fable 5.1"),
        ("opus", "Opus"),
    ])
    func modelDisplayNameParsesRecognizedShapes(id: String, expected: String) {
        #expect(ModelDisplayName.parse(id) == expected)
    }

    /// An ID that doesn't fit the family/version/date/bracket pattern comes
    /// back unchanged rather than mangled into something wrong-looking.
    @Test(arguments: [
        "",
        "5-5",
        "claude-",
        "claude-opus-5x",
        "claude-opus-abc-5",
        "not-a-real-model",
    ])
    func modelDisplayNameFallsBackToTheRawID(id: String) {
        #expect(ModelDisplayName.parse(id) == id)
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

    /// An unspecified context window means 1M, so only the 200K models carry
    /// a suffix. Fable has no 1M variant at all, so it carries none either.
    @Test(arguments: [
        (AgentModel.fable, "Fable 5.1"),
        (AgentModel.opus, "Opus 5.5"),
        (AgentModel.sonnet, "Sonnet 5"),
        (AgentModel.haiku, "Haiku 4.5"),
        (AgentModel.more[0], "Opus 5.5 200K"),
        (AgentModel.more[1], "Opus 5 200K"),
        (AgentModel.more[2], "Sonnet 5 200K"),
        (AgentModel.more[3], "Haiku 4.5 200K"),
    ])
    func labelsFollowTheContextWindowNamingRule(model: AgentModel, expectedLabel: String) {
        #expect(model.label == expectedLabel)
    }

    /// The primary menu is Default/Fable/Opus/Sonnet/Haiku 4.5; More holds
    /// each model's 200K variant, plus the prior-generation Opus kept
    /// reachable after Opus 5.5 took the top-level slot.
    @Test func moreHoldsExactlyThe200KVariants() {
        #expect(AgentModel.more.map(\.id) == [
            "claude-opus-5-5",
            "claude-opus-5",
            "claude-sonnet-5",
            "claude-haiku-4-5-20251001",
        ])
    }

    /// 200,000 and 1,000,000 are the exact figures a real `modelUsage` entry
    /// reports for a 200K and a 1M model, per `basic.ndjson`
    /// (`StreamJSONDecoderTests.largestContextWindowPicksTheMaxAcrossModelUsage`).
    @Test(arguments: [
        (AgentModel.fable, 1_000_000),
        (AgentModel.opus, 1_000_000),
        (AgentModel.sonnet, 1_000_000),
        (AgentModel.haiku, 1_000_000),
        (AgentModel.more[0], 200_000),
        (AgentModel.more[1], 200_000),
        (AgentModel.more[2], 200_000),
        (AgentModel.more[3], 200_000),
    ])
    func nominalContextWindowMatchesTheRealFigure(model: AgentModel, expected: Int) {
        #expect(model.nominalContextWindow == expected)
    }

    /// A model this build has never heard of assumes nothing, rather than
    /// guessing at a window it has no basis for.
    @Test func nominalContextWindowIsNilForAnUnrecognizedModel() {
        #expect(AgentModel(unrecognizedID: "claude-newthing-9").nominalContextWindow == nil)
    }
}
