import Testing
@testable import Plume

struct ModelEffortCommandTests {
    @Test(arguments: [
        (AgentModel.fable, "/model fable"),
        (AgentModel.opus, "/model opus"),
        (AgentModel.sonnet, "/model sonnet"),
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

    @Test(arguments: [
        ("claude-opus-5", AgentModel.opus),
        ("claude-fable-5", AgentModel.fable),
        ("sonnet", AgentModel.sonnet),
    ])
    func recognizingMapsKnownModelStrings(reported: String, expected: AgentModel) {
        #expect(AgentModel.recognizing(reported) == expected)
    }

    @Test
    func recognizingReturnsNilForAnUnrecognizedModelString() {
        #expect(AgentModel.recognizing("gpt-4") == nil)
        #expect(AgentModel.recognizing("") == nil)
    }

    /// A captured statusline payload reports a display name rather than the
    /// transcript's model ID, and either may carry a context-window suffix.
    @Test(arguments: [
        ("Opus 5", AgentModel.opus),
        ("Sonnet 5", AgentModel.sonnet),
        ("Fable 5", AgentModel.fable),
        ("claude-opus-5[1m]", AgentModel.opus),
        ("opus[1m]", AgentModel.opus),
    ])
    func recognizingMapsDisplayNamesAndContextSuffixes(reported: String, expected: AgentModel) {
        #expect(AgentModel.recognizing(reported) == expected)
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
