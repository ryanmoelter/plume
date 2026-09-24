import Foundation
import Testing
@testable import Plume

struct ModelEffortCommandTests {
    @Test(arguments: [
        (AgentModel.fable, "/model fable"),
        (AgentModel.opus, "/model opus[1m]"),
        (AgentModel.sonnet, "/model sonnet[1m]"),
        (AgentModel.haiku, "/model haiku[1m]"),
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

    /// A bracketed 1M alias is a plain token as far as the terminal is
    /// concerned — only whitespace could inject a second line.
    @Test func setModelKeepsTheContextSuffix() {
        #expect(ModelEffortCommand.setModel(.opus) == "/model opus[1m]")
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

    /// A bare alias reported back (by a statusline, say) lands on the
    /// matching versioned "More" entry, since that's the specific model the
    /// alias actually resolved to — see "Model aliases" in
    /// docs/headless-protocol.md.
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
    /// pass to `--model`, not a decoration to strip. `claude-opus-5-5[1m]` is
    /// also a previous release's top-level ID, which a persisted default
    /// from that release may still hold, and it must still round-trip.
    @Test(arguments: [
        ("claude-opus-5-5[1m]", AgentModel.opus5dot5),
        ("claude-opus-5[1m]", AgentModel.opus5),
        ("opus 5.5[1m]", AgentModel.opus5dot5),
        ("opus 5[1m]", AgentModel.opus5),
        ("sonnet 5[1m]", AgentModel.sonnet5),
        ("haiku 4.5[1m]", AgentModel.haiku4dot5),
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
        #expect(AgentModel.recognizing("fable[1m]") == .fable5dot1)
        #expect(AgentModel.fable5dot1.id == "claude-fable-5-1")
    }

    /// The top-level entries themselves are aliases the CLI resolves, so
    /// recognizing one back verbatim is also a no-op round trip.
    @Test(arguments: [
        AgentModel.fable, AgentModel.opus, AgentModel.sonnet, AgentModel.haiku
    ])
    func recognizingRoundTripsATopLevelAlias(model: AgentModel) {
        #expect(AgentModel.recognizing(model.id) == model)
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
    func recognizingIncludesCodexUltraEffort() {
        #expect(AgentEffort.recognizing("ultra") == .ultra)
    }

    @Test func recognizingPreservesAnUnknownProviderEffort() throws {
        let effort = try #require(AgentEffort.recognizing("deliberate"))
        #expect(effort.rawValue == "deliberate")
        #expect(effort.label == "deliberate")
        #expect(effort.id == "deliberate")
        #expect(ModelEffortCommand.setEffort(effort) == "/effort deliberate")
    }

    @Test func effortCodableUsesTheRawStringShape() throws {
        let data = try JSONEncoder().encode(AgentEffort(rawValue: "deliberate"))
        #expect(String(data: data, encoding: .utf8) == #""deliberate""#)
        #expect(try JSONDecoder().decode(AgentEffort.self, from: data).rawValue == "deliberate")
    }

    /// The top-level entries show bare family names, since the CLI — not
    /// Plume — picks the version. The "More" entries are explicit versioned
    /// IDs, so their labels carry a version and, for the 200K sibling, a
    /// size suffix.
    @Test(arguments: [
        (AgentModel.fable, "Fable"),
        (AgentModel.opus, "Opus"),
        (AgentModel.sonnet, "Sonnet"),
        (AgentModel.haiku, "Haiku"),
        (AgentModel.opus5dot5, "Opus 5.5"),
        (AgentModel.opus5dot5At200K, "Opus 5.5 200K"),
        (AgentModel.opus5, "Opus 5"),
        (AgentModel.opus5At200K, "Opus 5 200K"),
        (AgentModel.sonnet5, "Sonnet 5"),
        (AgentModel.sonnet5At200K, "Sonnet 5 200K"),
        (AgentModel.fable5dot1, "Fable 5.1"),
        (AgentModel.haiku4dot5, "Haiku 4.5"),
        (AgentModel.haiku4dot5At200K, "Haiku 4.5 200K"),
    ])
    func labelsFollowTheContextWindowNamingRule(model: AgentModel, expectedLabel: String) {
        #expect(model.label == expectedLabel)
    }

    /// The primary menu is Default/Fable/Opus/Sonnet/Haiku; More holds each
    /// specific version and its 200K sibling, plus the prior-generation Opus
    /// kept reachable after Opus 5.5 took the top-level slot.
    @Test func moreHoldsExactlyTheVersionedModels() {
        #expect(AgentModel.more.map(\.id) == [
            "claude-opus-5-5[1m]", "claude-opus-5-5",
            "claude-opus-5[1m]", "claude-opus-5",
            "claude-sonnet-5[1m]", "claude-sonnet-5",
            "claude-fable-5-1",
            "claude-haiku-4-5-20251001[1m]", "claude-haiku-4-5-20251001",
        ])
    }

    /// 200,000 and 1,000,000 are the exact figures a real `modelUsage` entry
    /// reports for a 200K and a 1M model, per `basic.ndjson`
    /// (`StreamJSONDecoderTests.largestContextWindowPicksTheMaxAcrossModelUsage`).
    /// A top-level alias with `[1m]` (or none, for Fable) means 1M; a bare
    /// 200K ID in "More" means 200K.
    @Test(arguments: [
        (AgentModel.fable, 1_000_000),
        (AgentModel.opus, 1_000_000),
        (AgentModel.sonnet, 1_000_000),
        (AgentModel.haiku, 1_000_000),
        (AgentModel.opus5dot5, 1_000_000),
        (AgentModel.opus5dot5At200K, 200_000),
        (AgentModel.opus5, 1_000_000),
        (AgentModel.opus5At200K, 200_000),
        (AgentModel.sonnet5, 1_000_000),
        (AgentModel.sonnet5At200K, 200_000),
        (AgentModel.fable5dot1, 1_000_000),
        (AgentModel.haiku4dot5, 1_000_000),
        (AgentModel.haiku4dot5At200K, 200_000),
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
