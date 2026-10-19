import Foundation
import Testing
@testable import Plume

/// Which artifact an Artifact tool row links to: the published page for a
/// publish, the named one for anything else, and none for a listing.
struct ArtifactToolCallTests {
    private let published = "https://claude.ai/code/artifact/0b6f9a1e-2f4c-4d1a-9c55-3e8a7d2b1f00"
    private let existing = "https://claude.ai/artifact/3f2a9c"

    @Test func onlyArtifactToolsAreRecognized() {
        #expect(ArtifactToolCall(name: "Read", input: [:]) == nil)
        #expect(ArtifactToolCall(name: "ArtifactComments", input: [:]) != nil)
    }

    @Test func aPublishLinksToThePageItsResultNames() {
        let call = ArtifactToolCall(name: "Artifact", input: ["file_path": .string("notes.html")])
        #expect(call?.action == "publish")
        #expect(call?.url(result: nil) == nil)
        #expect(call?.url(result: "Published \(published) (private).")?.absoluteString == published)
    }

    @Test func aRepublishFallsBackToTheInputURLWhenTheResultNamesNone() {
        let call = ArtifactToolCall(name: "Artifact", input: ["url": .string(existing)])
        #expect(call?.url(result: "Publish refused: conflict")?.absoluteString == existing)
    }

    @Test func aReadLinksToTheArtifactItNamedOverOnesItsResultMentions() {
        let call = ArtifactToolCall(name: "Artifact", input: ["action": .string("read"), "url": .string(existing)])
        #expect(call?.url(result: "Embeds \(published)")?.absoluteString == existing)
    }

    @Test(arguments: ["list", "quickstart", "delete"])
    func actionsWithoutOneLiveArtifactHaveNoLink(action: String) {
        let call = ArtifactToolCall(name: "Artifact", input: ["action": .string(action), "url": .string(existing)])
        #expect(call?.url(result: published) == nil)
    }

    @Test func aPublishTakesThePagesOwnTitleOverTheInputs() {
        let call = ArtifactToolCall(
            name: "Artifact",
            input: ["file_path": .string("/tmp/notes.html"), "title": .string("Fallback")],
            readsPageTitle: { _ in "Release notes" }
        )
        #expect(call?.title == "Release notes")
    }

    @Test func aPageWithoutATitleFallsBackToTheInput() {
        let call = ArtifactToolCall(
            name: "Artifact",
            input: ["file_path": .string("/tmp/notes.html"), "title": .string("Fallback")],
            readsPageTitle: { _ in nil }
        )
        #expect(call?.title == "Fallback")
    }

    @Test func onlyAPublishReadsThePage() {
        let call = ArtifactToolCall(
            name: "Artifact",
            input: ["action": .string("read"), "file_path": .string("/tmp/notes.html")],
            readsPageTitle: { _ in "Should not be read" }
        )
        #expect(call?.title == nil)
    }

    @Test func thePageTitleIsReadFromTheHeadAndCollapsesWhitespace() {
        let html = "<!doctype html><html><head><TITLE lang=\"en\">\n  Release\n  notes </TITLE></head></html>"
        #expect(ArtifactToolCall.pageTitle(inHTML: html) == "Release notes")
        #expect(ArtifactToolCall.pageTitle(inHTML: "<title>   </title>") == nil)
        #expect(ArtifactToolCall.pageTitle(inHTML: "<p>no title</p>") == nil)
    }

    @Test func thePageTitleIsReadFromAFileOnDisk() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).html")
        try "<html><head><title>On disk</title></head></html>".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(ArtifactToolCall.pageTitle(atPath: url.path) == "On disk")
        #expect(ArtifactToolCall.pageTitle(atPath: url.deletingPathExtension().appendingPathExtension("md").path) == nil)
    }

    @Test func onlyClaudeHostsCountAsArtifactLinks() {
        #expect(ArtifactToolCall.artifactURL(in: "see https://evil.example/artifact/abc") == nil)
        #expect(ArtifactToolCall.artifactURL(in: "see https://claude.ai.evil.example/artifact/abc") == nil)
        #expect(ArtifactToolCall.artifactURL(in: "at \(existing).")?.absoluteString == existing)
    }
}

/// The info pane's list: each linked artifact once, in first-touched order,
/// carrying the latest title any call gave it.
struct ConversationArtifactTests {
    private func message(_ calls: ToolCall...) -> ChatMessage {
        ChatMessage(id: UUID().uuidString, role: .assistant, blocks: calls.map { .toolCall($0) }, timestamp: nil)
    }

    private func artifactCall(_ input: [String: JSONValue], result: String?, title: String? = nil) -> ToolCall {
        ToolCall(
            id: UUID().uuidString,
            name: "Artifact",
            summary: ToolCallSummary(name: "Artifact"),
            input: .json("{}"),
            result: result,
            artifact: ArtifactToolCall(name: "Artifact", input: input, readsPageTitle: { _ in title })
        )
    }

    @Test func listsEachArtifactOnceWithItsLatestTitle() {
        let first = "https://claude.ai/code/artifact/aaa"
        let second = "https://claude.ai/code/artifact/bbb"
        let messages = [
            message(artifactCall(["file_path": .string("/tmp/a.html")], result: "Published \(first)", title: "Draft")),
            message(
                artifactCall(["file_path": .string("/tmp/b.html")], result: "Published \(second)", title: "Other"),
                artifactCall(["file_path": .string("/tmp/a.html"), "url": .string(first)], result: "Published \(first)", title: "Final")
            ),
        ]
        let artifacts = ConversationArtifact.artifacts(in: messages)
        #expect(artifacts.map(\.url.absoluteString) == [first, second])
        #expect(artifacts.map(\.title) == ["Final", "Other"])
    }

    @Test func aCallWithoutALinkIsLeftOut() {
        let messages = [
            message(artifactCall(["action": .string("list")], result: "https://claude.ai/code/artifact/aaa")),
            message(artifactCall(["file_path": .string("/tmp/a.html")], result: nil)),
        ]
        #expect(ConversationArtifact.artifacts(in: messages).isEmpty)
    }
}
