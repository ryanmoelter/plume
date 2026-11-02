import Foundation
import Testing
@testable import Plume

struct ConversationReferenceScannerTests {
    private func message(_ id: String, _ blocks: [ChatBlock], role: ChatMessage.Role = .assistant) -> ChatMessage {
        ChatMessage(id: id, role: role, blocks: blocks, timestamp: nil)
    }

    @Test func findsBareIdentifiersUppercaseOnly() {
        let found = ConversationReferenceScanner.references(in: "Fix PLUME-12 and DROID-7, not plume-3, UTF-8 or ABCDEFGH-1.")
        #expect(found.linearIdentifiers == ["PLUME-12", "DROID-7", "UTF-8"])
    }

    @Test func identifierMustStandAlone() {
        let found = ConversationReferenceScanner.references(in: "xPLUME-1 PLUME-2x PLUME-3_ (PLUME-4) ryanm/PLUME-5-fix")
        #expect(found.linearIdentifiers == ["PLUME-4", "PLUME-5"])
    }

    @Test func linearURLCountsInAnyCase() {
        let found = ConversationReferenceScanner.references(
            in: "See [it](https://linear.app/plume-term/issue/plume-318/link-linear-issues) and https://linear.app/x/issue/DROID-9"
        )
        #expect(found.linearIdentifiers == ["PLUME-318", "DROID-9"])
    }

    @Test func findsGitHubPullRequestURLs() {
        let found = ConversationReferenceScanner.references(
            in: "[#12](https://github.com/RyanMoelter/Plume/pull/12), https://github.com/a/b.c/pull/3/files and github.com/a/b/issues/4"
        )
        #expect(found.pullRequests == [
            PullRequestReference(owner: "ryanmoelter", repo: "plume", number: 12),
            PullRequestReference(owner: "a", repo: "b.c", number: 3),
        ])
    }

    @Test func assistantCodeIsNotScanned() {
        let reply = """
        Recent commits:
        ```
        abc1234 Fix thing
        PLUME-101 body https://github.com/a/b/pull/1
        ```
        Inline `PLUME-102` and ``https://linear.app/x/issue/PLUME-103`` stay quiet.
        ~~~sh
        PLUME-104
        ~~~
        Real mention: PLUME-105 and https://github.com/a/b/pull/2
        """
        var cache = ConversationReferenceScanner.Cache()
        let found = ConversationReferenceScanner.scan([message("m", [.markdown(reply)])], cache: &cache)
        #expect(found.linearIdentifiers == ["PLUME-105"])
        #expect(found.pullRequests == [PullRequestReference(owner: "a", repo: "b", number: 2)])
    }

    @Test func userCodeIsStillScanned() {
        var cache = ConversationReferenceScanner.Cache()
        let found = ConversationReferenceScanner.scan(
            [message("m", [.markdown("see `PLUME-7`\n```\nPLUME-8\n```")], role: .user)],
            cache: &cache
        )
        #expect(found.linearIdentifiers == ["PLUME-7", "PLUME-8"])
    }

    @Test func unclosedFenceHidesTheRest() {
        #expect(ConversationReferenceScanner.removingCode(from: "PLUME-1\n```\nPLUME-2").contains("PLUME-2") == false)
    }

    @Test func scansOnlyProse() {
        var call = ToolCall(id: "t", name: "Bash", summary: ToolCallSummary(name: "Bash"), input: .json("{\"x\": \"PLUME-1\"}"))
        call.result = "PLUME-2"
        let messages = [
            message("u", [.markdown("PLUME-3"), .injected(.commandOutput(), text: "PLUME-4"), .injected(.pastedContent, text: "PLUME-8")], role: .user),
            message("a", [.thinking("PLUME-5"), .toolCall(call), .markdown("PLUME-6")]),
            message("n", [.markdown("PLUME-7")], role: .notice),
        ]
        var cache = ConversationReferenceScanner.Cache()
        #expect(ConversationReferenceScanner.scan(messages, cache: &cache).linearIdentifiers == ["PLUME-3", "PLUME-8", "PLUME-6"])
    }

    @Test func rescansAMessageOnlyWhenItGrows() {
        var cache = ConversationReferenceScanner.Cache()
        _ = ConversationReferenceScanner.scan([message("a", [.markdown("PLUME-1")])], cache: &cache)

        // Same id and size, different text: the cached answer stands.
        let unchanged = ConversationReferenceScanner.scan([message("a", [.markdown("PLUME-2")])], cache: &cache)
        #expect(unchanged.linearIdentifiers == ["PLUME-1"])

        let grown = ConversationReferenceScanner.scan([message("a", [.markdown("PLUME-1 PLUME-22")])], cache: &cache)
        #expect(grown.linearIdentifiers == ["PLUME-1", "PLUME-22"])
    }

    @Test func pullRequestReferenceMatchesItsURL() {
        let reference = PullRequestReference(owner: "a", repo: "b", number: 3)
        #expect(reference.matches(url: "https://github.com/A/B/pull/3"))
        #expect(!reference.matches(url: "https://github.com/a/b/pull/33"))
        #expect(!reference.matches(url: nil))
    }
}
