import Testing
import Foundation
@testable import Plume

/// Fixtures are real captures of `claude -p --output-format stream-json`,
/// under `PlumeTests/Fixtures/Headless`. `docs/headless-protocol.md` is the
/// reference this locks the decoder and encoder against.
struct StreamJSONDecoderTests {
    private static func fixtureDirectory() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // PlumeTests
            .appendingPathComponent("Fixtures/Headless")
    }

    private func lines(_ fixture: String) throws -> [String] {
        let url = Self.fixtureDirectory().appendingPathComponent("\(fixture).ndjson")
        let contents = try String(contentsOf: url, encoding: .utf8)
        return contents
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
    }

    private func messages(_ fixture: String) throws -> [StreamJSONMessage] {
        try lines(fixture).compactMap { StreamJSONDecoder.decode(line: $0) }
    }

    // MARK: - Every line decodes to something recognized

    @Test(arguments: ["basic", "control4", "askq2", "exitplan", "multiturn"])
    func everyLineDecodesToAKnownMessage(fixture: String) throws {
        let raw = try lines(fixture)
        try #require(!raw.isEmpty, "\(fixture) fixture is empty")

        let decoded = raw.map { StreamJSONDecoder.decode(line: $0) }
        #expect(decoded.count == raw.count, "\(fixture): a line failed to decode at all")

        for (index, message) in decoded.enumerated() {
            guard let message else {
                Issue.record("\(fixture) line \(index) decoded to nil")
                continue
            }
            if case .unknown(let type) = message {
                Issue.record("\(fixture) line \(index) decoded as .unknown(\(type))")
            }
        }
    }

    // MARK: - control4: a real can_use_tool request

    @Test func control4YieldsACanUseToolRequestForWrite() throws {
        let requests = try messages("control4").compactMap { message -> ControlRequest? in
            guard case .controlRequest(let request) = message else { return nil }
            return request
        }
        let request = try #require(requests.first { $0.subtype == "can_use_tool" })

        #expect(request.toolName == "Write")
        #expect(request.displayName == "Write")
        #expect(request.input["file_path"]?.stringValue == "/tmp/plume-probe-w2.txt")
        #expect(request.input["content"]?.stringValue == "hello\n")
        #expect(request.decisionReason == "Path is outside allowed working directories")
        #expect(request.toolUseID == "toolu_01LQi2WmhgnUJsfGaoCSuiah")
        // Write isn't in the always-ask class, unlike AskUserQuestion/ExitPlanMode.
        #expect(request.requiresUserInteraction == false)
    }

    // MARK: - askq2: an AskUserQuestion permission request

    @Test func askq2YieldsAnAskUserQuestionRequestWithDecodableOptions() throws {
        let requests = try messages("askq2").compactMap { message -> ControlRequest? in
            guard case .controlRequest(let request) = message else { return nil }
            return request
        }
        let request = try #require(requests.first { $0.toolName == "AskUserQuestion" })

        #expect(request.subtype == "can_use_tool")
        #expect(request.requiresUserInteraction)

        let payload = InteractiveToolPayload.decoding(name: "AskUserQuestion", input: request.input)
        guard case .questions(let questions)? = payload else {
            Issue.record("expected a decoded questions payload")
            return
        }
        #expect(questions.count == 1)
        #expect(questions[0].header == "Indentation")
        #expect(questions[0].question == "Do you prefer tabs or spaces for indentation?")
        #expect(questions[0].multiSelect == false)
        #expect(questions[0].options.map(\.label) == ["Spaces", "Tabs"])
        #expect(questions[0].options[1].description.contains("tab characters"))
    }

    // MARK: - exitplan: an ExitPlanMode request carrying the plan text

    @Test func exitplanYieldsAnExitPlanModeRequestWithThePlanText() throws {
        let requests = try messages("exitplan").compactMap { message -> ControlRequest? in
            guard case .controlRequest(let request) = message else { return nil }
            return request
        }
        let request = try #require(requests.first { $0.toolName == "ExitPlanMode" })

        #expect(request.requiresUserInteraction)

        let payload = InteractiveToolPayload.decoding(name: "ExitPlanMode", input: request.input)
        guard case .plan(let markdown, let filePath)? = payload else {
            Issue.record("expected a decoded plan payload")
            return
        }
        #expect(markdown.contains("Add a comment to the README."))
        #expect(filePath == "/tmp/example/plans/make-a-one-line-plan-enumerated-wadler.md")
    }

    // MARK: - multiturn: multiple results, one stable session id

    @Test func multiturnYieldsMultipleResultsWithAStableSessionID() throws {
        let raw = try lines("multiturn")
        let sessionIDs = raw.compactMap { line -> String? in
            guard let data = line.data(using: .utf8),
                  let root = try? JSONDecoder().decode([String: JSONValue].self, from: data)
            else { return nil }
            return root["session_id"]?.stringValue
        }
        try #require(!sessionIDs.isEmpty)
        #expect(Set(sessionIDs).count == 1, "expected one stable session id across the fixture")

        let results = try messages("multiturn").compactMap { message -> TurnResult? in
            guard case .result(let result) = message else { return nil }
            return result
        }
        #expect(results.count == 3)
        #expect(results.allSatisfy { $0.subtype == "success" })
        #expect(results.allSatisfy { $0.isError == false })
    }

    // MARK: - largestContextWindow

    @Test func largestContextWindowPicksTheMaxAcrossModelUsage() throws {
        let results = try messages("basic").compactMap { message -> TurnResult? in
            guard case .result(let result) = message else { return nil }
            return result
        }
        let result = try #require(results.first)
        // basic.ndjson's modelUsage carries haiku (200000) and opus (1000000).
        #expect(result.contextWindow == 1_000_000)
    }

    @Test func largestContextWindowHandlesEmptyAndSingleEntryMaps() {
        #expect(StreamJSONDecoder.decode(root: [
            "type": .string("result"),
            "modelUsage": .object([:])
        ]) != nil)

        let singleRoot: [String: JSONValue] = [
            "type": .string("result"),
            "modelUsage": .object([
                "some-model": .object(["contextWindow": .number(200_000)])
            ])
        ]
        guard case .result(let result)? = StreamJSONDecoder.decode(root: singleRoot) else {
            Issue.record("expected a result message")
            return
        }
        #expect(result.contextWindow == 200_000)
    }

    // MARK: - Context usage

    /// Cached input is nearly all of the context in any conversation past its
    /// first turn. These numbers are copied from a real transcript: counting
    /// only `input_tokens` reported 160 tokens where 270,724 were in use.
    @Test func contextUsageCountsCachedInputNotJustTheUncachedRemainder() {
        let root: [String: JSONValue] = [
            "type": .string("result"),
            "usage": .object([
                "input_tokens": .number(2),
                "cache_creation_input_tokens": .number(547),
                "cache_read_input_tokens": .number(270_017),
                "output_tokens": .number(158)
            ])
        ]
        guard case .result(let result)? = StreamJSONDecoder.decode(root: root) else {
            Issue.record("expected a result message")
            return
        }
        #expect(result.contextUsedTokens == 270_724)
    }

    @Test func contextUsageIsNilWhenTheTurnReportsNoUsageAtAll() {
        let root: [String: JSONValue] = ["type": .string("result")]
        guard case .result(let result)? = StreamJSONDecoder.decode(root: root) else {
            Issue.record("expected a result message")
            return
        }
        #expect(result.contextUsedTokens == nil)
    }

    /// An older or partial payload still totals what it does report, rather
    /// than dropping to nil because one field is missing.
    @Test func contextUsageTotalsWhicheverFieldsArePresent() {
        let root: [String: JSONValue] = [
            "type": .string("result"),
            "usage": .object([
                "input_tokens": .number(1_200),
                "output_tokens": .number(300)
            ])
        ]
        guard case .result(let result)? = StreamJSONDecoder.decode(root: root) else {
            Issue.record("expected a result message")
            return
        }
        #expect(result.contextUsedTokens == 1_500)
    }

    // MARK: - Encoder round-trips

    private func decodedRoot(_ line: String?) throws -> [String: JSONValue] {
        let line = try #require(line)
        let data = try #require(line.data(using: .utf8))
        return try JSONDecoder().decode([String: JSONValue].self, from: data)
    }

    @Test func userTurnRoundTripsAsAUserMessageWithTextContent() throws {
        let root = try decodedRoot(StreamJSONEncoder.userTurn(text: "hello there"))

        #expect(root["type"]?.stringValue == "user")
        let message = try #require(root["message"]?.objectValue)
        #expect(message["role"]?.stringValue == "user")
        let content = try #require(message["content"]?.arrayValue)
        #expect(content.count == 1)
        let block = try #require(content.first?.objectValue)
        #expect(block["type"]?.stringValue == "text")
        #expect(block["text"]?.stringValue == "hello there")
    }

    @Test func initializeRoundTripsAsAControlRequest() throws {
        let root = try decodedRoot(StreamJSONEncoder.initialize(requestID: "init-1"))

        #expect(root["type"]?.stringValue == "control_request")
        #expect(root["request_id"]?.stringValue == "init-1")
        let request = try #require(root["request"]?.objectValue)
        #expect(request["subtype"]?.stringValue == "initialize")
        #expect(request["hooks"]?.objectValue == [:])

        guard case .controlRequest(let decoded)? = StreamJSONDecoder.decode(root: root) else {
            Issue.record("expected a control request")
            return
        }
        #expect(decoded.requestID == "init-1")
        #expect(decoded.subtype == "initialize")
    }

    @Test func interruptRoundTripsAsAControlRequest() throws {
        let root = try decodedRoot(StreamJSONEncoder.interrupt(requestID: "int-1"))

        #expect(root["type"]?.stringValue == "control_request")
        #expect(root["request_id"]?.stringValue == "int-1")
        let request = try #require(root["request"]?.objectValue)
        #expect(request["subtype"]?.stringValue == "interrupt")

        guard case .controlRequest(let decoded)? = StreamJSONDecoder.decode(root: root) else {
            Issue.record("expected a control request")
            return
        }
        #expect(decoded.subtype == "interrupt")
    }

    @Test func permissionResponseAllowRoundTripsWithUpdatedInput() throws {
        let updatedInput: [String: JSONValue] = ["file_path": .string("/tmp/x.txt")]
        let root = try decodedRoot(StreamJSONEncoder.permissionResponse(
            requestID: "req-1",
            decision: .allow(updatedInput: updatedInput)
        ))

        #expect(root["type"]?.stringValue == "control_response")
        let response = try #require(root["response"]?.objectValue)
        #expect(response["subtype"]?.stringValue == "success")
        #expect(response["request_id"]?.stringValue == "req-1")
        let payload = try #require(response["response"]?.objectValue)
        #expect(payload["behavior"]?.stringValue == "allow")
        #expect(payload["updatedInput"]?.objectValue == updatedInput)

        guard case .controlResponse(let decoded)? = StreamJSONDecoder.decode(root: root) else {
            Issue.record("expected a control response")
            return
        }
        #expect(decoded.requestID == "req-1")
        #expect(decoded.payload["behavior"]?.stringValue == "allow")
    }

    @Test func permissionResponseDenyRoundTripsWithAMessage() throws {
        let root = try decodedRoot(StreamJSONEncoder.permissionResponse(
            requestID: "req-2",
            decision: .deny(message: "not allowed")
        ))

        let response = try #require(root["response"]?.objectValue)
        let payload = try #require(response["response"]?.objectValue)
        #expect(payload["behavior"]?.stringValue == "deny")
        #expect(payload["message"]?.stringValue == "not allowed")

        guard case .controlResponse(let decoded)? = StreamJSONDecoder.decode(root: root) else {
            Issue.record("expected a control response")
            return
        }
        #expect(decoded.payload["behavior"]?.stringValue == "deny")
        #expect(decoded.payload["message"]?.stringValue == "not allowed")
    }

    @Test func answeredQuestionInputAddsAnAnswersMapKeyedByQuestionText() throws {
        let original: [String: JSONValue] = [
            "questions": .array([.object(["question": .string("Tabs or spaces?")])])
        ]
        let updated = StreamJSONEncoder.answeredQuestionInput(
            original: original,
            answers: ["Tabs or spaces?": "Tabs"]
        )

        #expect(updated["questions"] == original["questions"])
        let answers = updated["answers"]?.objectValue
        #expect(answers?["Tabs or spaces?"]?.stringValue == "Tabs")

        // As sent in an allow response, this is what the model sees as chosen.
        let root = try decodedRoot(StreamJSONEncoder.permissionResponse(
            requestID: "req-3",
            decision: .allow(updatedInput: updated)
        ))
        let payload = root["response"]?.objectValue?["response"]?.objectValue
        #expect(payload?["updatedInput"]?.objectValue?["answers"]?.objectValue?["Tabs or spaces?"]?.stringValue == "Tabs")
    }

    // MARK: - HeadlessCommand argv

    @Test func headlessCommandArgvIncludesTheRequiredFlags() {
        let arguments = HeadlessCommand.arguments(
            resumeSessionID: nil,
            permissionMode: .acceptEdits,
            settingsPath: nil
        )

        #expect(arguments.contains("claude"))
        #expect(contains(arguments, flag: "--output-format", value: "stream-json"))
        #expect(contains(arguments, flag: "--input-format", value: "stream-json"))
        #expect(arguments.contains("--include-partial-messages"))
        #expect(arguments.contains("--verbose"))
        #expect(contains(arguments, flag: "--permission-prompt-tool", value: "stdio"))
        #expect(contains(arguments, flag: "--permission-mode", value: "acceptEdits"))
    }

    @Test func headlessCommandDefaultsPermissionModeWhenNilRatherThanOmittingIt() {
        let arguments = HeadlessCommand.arguments(
            resumeSessionID: nil,
            permissionMode: nil,
            settingsPath: nil
        )
        // A `-p` session starts in Manual on every plan, so a mode is always
        // passed explicitly rather than left to the CLI's default.
        #expect(contains(arguments, flag: "--permission-mode", value: "acceptEdits"))
    }

    private func contains(_ arguments: [String], flag: String, value: String) -> Bool {
        guard let index = arguments.firstIndex(of: flag) else { return false }
        let next = arguments.index(after: index)
        return next < arguments.endIndex && arguments[next] == value
    }
}
