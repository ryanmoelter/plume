import Foundation
import Testing
@testable import Plume

/// A `SendUserFile` call draws its images inline and every other file as a
/// card, unless the call asks to attach, which makes every file a card.
struct SentUserFilesTests {
    private let screenshot = "/tmp/shots/A1-home.png"
    private let report = "/tmp/shots/report.pdf"

    private func input(files: [String], caption: String? = nil, display: String? = nil) -> [String: JSONValue] {
        var input: [String: JSONValue] = ["files": .array(files.map { .string($0) }), "status": .string("normal")]
        if let caption { input["caption"] = .string(caption) }
        if let display { input["display"] = .string(display) }
        return input
    }

    @Test func onlySendUserFileIsRecognized() {
        #expect(SentUserFiles(name: "Read", input: input(files: [screenshot])) == nil)
        #expect(SentUserFiles(name: "SendUserFile", input: input(files: [screenshot])) != nil)
    }

    @Test func aCallWithNoFilesIsNotRecognized() {
        #expect(SentUserFiles(name: "SendUserFile", input: input(files: [])) == nil)
        #expect(SentUserFiles(name: "SendUserFile", input: input(files: [""])) == nil)
    }

    @Test func renderDrawsImagesInlineAndCardsTheRest() throws {
        let sent = try #require(SentUserFiles(
            name: "SendUserFile",
            input: input(files: [screenshot, report], caption: "  Before and after  ", display: "render")
        ))
        #expect(sent.caption == "Before and after")
        #expect(sent.inlineImages.map(\.path) == [screenshot])
        #expect(sent.cards.map(\.path) == [report])
    }

    @Test func attachMakesEveryFileACard() throws {
        let sent = try #require(SentUserFiles(
            name: "SendUserFile",
            input: input(files: [screenshot, report], display: "attach")
        ))
        #expect(sent.inlineImages.isEmpty)
        #expect(sent.cards.count == 2)
    }

    @Test func aMissingDisplayRenders() throws {
        let sent = try #require(SentUserFiles(name: "SendUserFile", input: input(files: [screenshot])))
        #expect(sent.display == .render)
        #expect(sent.caption == nil)
    }

    @Test func aTildePathExpands() throws {
        let sent = try #require(SentUserFiles(name: "SendUserFile", input: input(files: ["~/shot.PNG"])))
        #expect(sent.files[0].path == (NSHomeDirectory() as NSString).appendingPathComponent("shot.PNG"))
        #expect(sent.inlineImages.count == 1)
    }

    @Test func theParserAttachesTheFilesToTheCall() throws {
        let line = #"{"type":"assistant","uuid":"a1","isSidechain":false,"message":{"id":"msg_1","role":"assistant","content":[{"type":"tool_use","id":"toolu_1","name":"SendUserFile","input":{"files":["/tmp/shots/A1-home.png"],"caption":"Home","status":"normal","display":"render"}}]}}"#
        let transcript = TranscriptParser.parse(Data(line.utf8))
        guard case .toolCall(let call)? = transcript.messages.first?.blocks.first else {
            Issue.record("expected a tool call")
            return
        }
        #expect(call.sentFiles?.files.map(\.path) == [screenshot])
        #expect(call.summary.detail == "Home")
    }
}

/// An `Agent` call links to the subagent whose descriptor names its tool use.
struct ChatSubagentOpenerTests {
    private func subagent(_ id: String, toolUseID: String?) -> SubagentTranscript {
        SubagentTranscript(
            id: id,
            transcript: Transcript(),
            modifiedAt: nil,
            descriptor: SubagentDescriptor(description: "Explore", toolUseID: toolUseID)
        )
    }

    @Test func findsTheSubagentItsCallSpawned() {
        let subagents = [subagent("a1", toolUseID: "toolu_1"), subagent("a2", toolUseID: "toolu_2")]
        #expect(ChatSubagentOpener.subagent(forToolUseID: "toolu_2", in: subagents)?.id == "a2")
    }

    @Test func aCallWithNoSubagentYetFindsNone() {
        let subagents = [subagent("a1", toolUseID: nil)]
        #expect(ChatSubagentOpener.subagent(forToolUseID: "toolu_1", in: subagents) == nil)
    }
}
