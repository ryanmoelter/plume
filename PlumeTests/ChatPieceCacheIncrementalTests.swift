import Foundation
import Testing
@testable import Plume

/// Drives one long-lived `ChatPieceCache` through sequences of builds and
/// checks every build's pieces, reference targets and outline against a fresh
/// cache given the same inputs, while counting how many messages each build
/// actually re-split.
@MainActor
struct ChatPieceCacheIncrementalTests {
    @MainActor
    struct Inputs {
        var messages: [ChatMessage]
        var status: TaskStatus = .awaitingReply
        var hidden: Set<String> = []
        var expanded: Set<String> = []
        var dimensions = Dimensions(bodySize: 13)
        var revision = 0
        var linkBase: URL? = URL(fileURLWithPath: "/repo")
        var titles: [ReferenceTarget: String] = [:]
    }

    static func build(_ cache: ChatPieceCache, _ inputs: Inputs) -> [ChatPiece] {
        let titles = inputs.titles
        return cache.pieces(
            for: inputs.messages,
            status: inputs.status,
            hiddenToolUseIDs: inputs.hidden,
            expandedAgentMessages: inputs.expanded,
            dimensions: inputs.dimensions,
            referenceRevision: inputs.revision,
            linkBase: inputs.linkBase,
            referenceTitle: { titles[$0] }
        )
    }

    /// Returns how many messages the build re-split.
    @discardableResult
    private func step(
        _ cache: ChatPieceCache,
        _ inputs: Inputs,
        sourceLocation: SourceLocation = #_sourceLocation
    ) -> Int {
        let splitsBefore = cache.splitCount
        let pieces = Self.build(cache, inputs)
        let fresh = ChatPieceCache()
        let expected = Self.build(fresh, inputs)
        #expect(pieces == expected, sourceLocation: sourceLocation)
        #expect(cache.referenceTargets == fresh.referenceTargets, sourceLocation: sourceLocation)
        #expect(cache.outline == fresh.outline, sourceLocation: sourceLocation)
        #expect(cache.outline == ChatOutlineBuilder.outline(from: expected), sourceLocation: sourceLocation)
        return cache.splitCount - splitsBefore
    }

    private func message(
        _ id: String,
        _ role: ChatMessage.Role = .assistant,
        _ blocks: [ChatBlock],
        isLive: Bool = false
    ) -> ChatMessage {
        ChatMessage(id: id, role: role, blocks: blocks, timestamp: nil, isLive: isLive)
    }

    private func assistant(_ id: String, _ blocks: [ChatBlock], isLive: Bool = false) -> ChatMessage {
        message(id, .assistant, blocks, isLive: isLive)
    }

    private func user(_ id: String, _ text: String) -> ChatMessage {
        message(id, .user, [.markdown(text)])
    }

    private func toolCall(_ id: String, result: String? = nil) -> ChatBlock {
        .toolCall(ToolCall(
            id: id,
            name: "Read",
            summary: ToolCallSummary(name: "Read", detail: "a file"),
            input: .json("{}"),
            result: result
        ))
    }

    private var conversation: [ChatMessage] {
        [
            user("u0", "Look at **this**, please."),
            assistant("a0", [.markdown("First paragraph.\n\nSecond paragraph.\n\n- one\n- two"), toolCall("t0", result: "ok")]),
            user("u1", "And then?"),
            assistant("a1", [.thinking("hm"), .markdown("# Done\n\n```swift\nlet x = 1\n```\n\nAll set.")]),
        ]
    }

    // MARK: - Growth

    @Test func appendingAndStreamingReSplitOnlyTheNewestMessage() {
        let cache = ChatPieceCache()
        var inputs = Inputs(messages: conversation)
        #expect(step(cache, inputs) == 4)
        #expect(step(cache, inputs) == 0)

        inputs.messages.append(user("u2", "Next question."))
        #expect(step(cache, inputs) == 1)

        inputs.status = .working
        #expect(step(cache, inputs) == 1)

        // The prompt loses the activity it held as the last message.
        inputs.messages.append(assistant("a2", [.markdown("Stre")], isLive: true))
        #expect(step(cache, inputs) == 2)
        inputs.messages[5] = assistant("a2", [.markdown("Streaming a longer reply.\n\nWith a second")], isLive: true)
        #expect(step(cache, inputs) == 1)
        inputs.messages[5] = assistant("a2", [.markdown("Streaming a longer reply.\n\nWith a second paragraph."), toolCall("t2")], isLive: true)
        #expect(step(cache, inputs) == 1)
        inputs.messages[5] = assistant("a2", [
            .markdown("Streaming a longer reply.\n\nWith a second paragraph."),
            toolCall("t2", result: "done"),
            .markdown("Finished."),
        ])
        inputs.status = .awaitingReply
        #expect(step(cache, inputs) == 1)
    }

    @Test func aCacheWithoutLinksMatchesThePlainSplitter() {
        let cache = ChatPieceCache()
        var messages = conversation
        for count in 1...messages.count {
            let pieces = Self.build(cache, Inputs(messages: Array(messages.prefix(count)), status: .working))
            #expect(pieces == ChatPieceSplitter.pieces(
                for: Array(messages.prefix(count)),
                status: .working,
                hiddenToolUseIDs: [],
                dimensions: Dimensions(bodySize: 13)
            ))
        }
        messages[1] = assistant("a0", [.markdown("Rewritten.")])
        #expect(Self.build(cache, Inputs(messages: messages)) == ChatPieceSplitter.pieces(
            for: messages,
            status: .awaitingReply,
            hiddenToolUseIDs: [],
            dimensions: Dimensions(bodySize: 13)
        ))
    }

    // MARK: - Status

    /// The activity indicator, the attention wash, a pending call and the
    /// copy footer all move with the status, between the last message and the
    /// standalone indicator below a prompt.
    @Test func statusChangesMoveTheLiveTreatment() {
        let cache = ChatPieceCache()
        var inputs = Inputs(messages: conversation + [assistant("a2", [.markdown("Asking."), toolCall("t2")])])
        step(cache, inputs)
        for status in [TaskStatus.working, .awaitingReply, .questionAsked, .permissionNeeded, .waitingOnSubagents, .awaitingReply] {
            inputs.status = status
            #expect(step(cache, inputs) <= 1)
        }

        inputs.messages.append(user("u3", "Go on."))
        inputs.status = .working
        #expect(step(cache, inputs) == 1)
        inputs.status = .questionAsked
        step(cache, inputs)
        inputs.status = .awaitingReply
        step(cache, inputs)
    }

    @Test func hiddenToolCallsFollowTheLastMessage() {
        let cache = ChatPieceCache()
        var inputs = Inputs(
            messages: conversation + [assistant("a2", [.markdown("Running."), toolCall("t2")])],
            status: .permissionNeeded,
            hidden: ["t2"]
        )
        step(cache, inputs)
        inputs.hidden = []
        #expect(step(cache, inputs) == 1)
        inputs.hidden = ["t2"]
        #expect(step(cache, inputs) == 1)

        // The hidden call no longer belongs to the last message, which also
        // changes the kind the next message is spaced from.
        inputs.messages.append(assistant("a3", [toolCall("t3")]))
        step(cache, inputs)
        inputs.hidden = []
        step(cache, inputs)
    }

    /// A message ending in a call spaces what follows it differently from one
    /// ending in prose, so changing that message re-splits its successor too.
    @Test func aPredecessorsLastKindRespacesTheNextMessage() {
        let cache = ChatPieceCache()
        var inputs = Inputs(messages: conversation + [user("u2", "Then?"), assistant("a2", [toolCall("t2")])])
        step(cache, inputs)
        inputs.messages[3] = assistant("a1", [.thinking("hm"), .markdown("All set."), toolCall("t1")])
        #expect(step(cache, inputs) == 2)
        inputs.messages[3] = assistant("a1", [toolCall("t1")])
        step(cache, inputs)
    }

    // MARK: - Agent messages and slash commands

    @Test func expandingAnAgentMessageReSplitsOnlyItsMessage() {
        let long = "<agent-message from=\"a1\">\n\((1...20).map { "Line \($0)." }.joined(separator: "\n\n"))\n</agent-message>"
        let agent = message("m", .user, [.injected(.agentMessage(name: "Explore: look", subagentID: "a1"), text: long)])
        let cache = ChatPieceCache()
        var inputs = Inputs(messages: [conversation[0], agent] + conversation.dropFirst())
        step(cache, inputs)
        inputs.expanded = ["m/0"]
        #expect(step(cache, inputs) == 1)
        inputs.expanded = ["m/0", "elsewhere/0"]
        #expect(step(cache, inputs) == 0)
        inputs.expanded = []
        #expect(step(cache, inputs) == 1)
    }

    @Test func aSlashCommandsExpansionFollowsItsCommand() {
        let command = ChatBlock.injected(
            .slashCommand(name: "/review", arguments: "DROID-344"),
            text: "<command-name>/review</command-name>\n<command-args>DROID-344</command-args>"
        )
        let skill = ChatBlock.injected(.skill(name: "review"), text: "Base directory for this skill: /x/review")
        let cache = ChatPieceCache()
        var inputs = Inputs(messages: conversation + [message("c", .user, [command])])
        step(cache, inputs)
        inputs.messages.append(message("p", .user, [skill]))
        #expect(step(cache, inputs) == 1)
        inputs.messages[4] = user("c", "/review DROID-344, typed as text")
        #expect(step(cache, inputs) == 2)
        inputs.messages[4] = message("c", .user, [command])
        step(cache, inputs)
    }

    // MARK: - Middle and removal

    @Test func aToolResultInTheMiddleReSplitsOnlyItsMessage() {
        let cache = ChatPieceCache()
        var inputs = Inputs(messages: conversation)
        inputs.messages[1] = assistant("a0", [.markdown("First paragraph."), toolCall("t0")])
        step(cache, inputs)
        inputs.messages[1] = assistant("a0", [.markdown("First paragraph."), toolCall("t0", result: "contents")])
        #expect(step(cache, inputs) == 1)
    }

    @Test func messagesRemovedFromTheEndOrMiddle() {
        let cache = ChatPieceCache()
        var inputs = Inputs(
            messages: conversation + [user("u2", "More."), assistant("a2", [toolCall("t2"), .markdown("Ok.")])],
            status: .working
        )
        step(cache, inputs)
        inputs.messages.removeLast()
        step(cache, inputs)
        inputs.messages.remove(at: 1)
        step(cache, inputs)
        inputs.messages.append(assistant("a3", [.markdown("Forked reply.")]))
        step(cache, inputs)
    }

    // MARK: - Dimensions and parsing

    @Test func aWidthChangeReSplitsEverythingAndParsesNothing() {
        let cache = ChatPieceCache()
        var inputs = Inputs(messages: conversation)
        step(cache, inputs)
        let parsed = cache.parseCount
        #expect(parsed > 0)

        inputs.dimensions = Dimensions(bodySize: 16)
        #expect(step(cache, inputs) == inputs.messages.count)
        inputs.dimensions = Dimensions(bodySize: 13)
        #expect(step(cache, inputs) == inputs.messages.count)
        #expect(cache.parseCount == parsed)
    }

    @Test func appendingParsesOnlyTheNewText() {
        let cache = ChatPieceCache()
        var inputs = Inputs(messages: conversation)
        step(cache, inputs)
        let parsed = cache.parseCount
        inputs.messages.append(user("u2", "Brand new."))
        step(cache, inputs)
        #expect(cache.parseCount == parsed + 1)
    }

    // MARK: - Chip titles

    private let issueURL = "https://linear.app/p/issue/PLUME-1/slug"

    @Test func aReferenceTitleArrivingReachesAnEarlyMessage() {
        let cache = ChatPieceCache()
        var inputs = Inputs(messages: [user("u0", "Fix [PLUME-1](\(issueURL)).")] + conversation.dropFirst())
        step(cache, inputs)
        #expect(cache.referenceTargets == [.linear(identifier: "PLUME-1")])

        inputs.messages.append(user("u2", "Status?"))
        #expect(step(cache, inputs) == 1)

        inputs.revision = 1
        inputs.titles = [.linear(identifier: "PLUME-1"): "Add chips"]
        #expect(step(cache, inputs) == 1)

        inputs.revision = 2
        inputs.titles = [.linear(identifier: "PLUME-1"): "Add chips, renamed"]
        #expect(step(cache, inputs) == 1)

        // A new revision that leaves this title alone reuses the message.
        inputs.revision = 3
        inputs.titles[.linear(identifier: "PLUME-2")] = "Unrelated"
        #expect(step(cache, inputs) == 0)
    }

    private func artifactCall(_ id: String, url: String, title: String) -> ChatBlock {
        .toolCall(ToolCall(
            id: id,
            name: "Artifact",
            summary: ToolCallSummary(name: "Artifact"),
            input: .json("{}"),
            result: "Published \(url)",
            artifact: ArtifactToolCall(name: "Artifact", input: ["file_path": .string("/tmp/a.html")], readsPageTitle: { _ in title })
        ))
    }

    @Test func aLaterArtifactCallRetitlesAnEarlierChip() {
        let url = "https://claude.ai/code/artifact/0f2c"
        let cache = ChatPieceCache()
        var inputs = Inputs(messages: conversation + [assistant("a2", [.markdown("See [the page](\(url)) or \(url).")])])
        step(cache, inputs)

        inputs.messages.append(assistant("a3", [artifactCall("t3", url: url, title: "Release notes")]))
        #expect(step(cache, inputs) == 2)

        inputs.messages.append(assistant("a4", [artifactCall("t4", url: url, title: "Release notes, v2")]))
        #expect(step(cache, inputs) == 2)

        inputs.messages.removeLast(2)
        step(cache, inputs)
    }

    @Test func aLinkBaseChangeReclassifiesEveryLink() {
        let cache = ChatPieceCache()
        var inputs = Inputs(
            messages: [user("u0", "Open [a](src/a.swift) and [PLUME-1](\(issueURL)).")] + conversation.dropFirst(),
            titles: [
                .file(path: "/repo/src/a.swift"): "a.swift",
                .linear(identifier: "PLUME-1"): "Add chips",
            ]
        )
        step(cache, inputs)
        let parsed = cache.parseCount

        inputs.linkBase = URL(fileURLWithPath: "/other")
        step(cache, inputs)
        inputs.linkBase = nil
        step(cache, inputs)
        inputs.linkBase = URL(fileURLWithPath: "/repo")
        step(cache, inputs)
        #expect(cache.parseCount == parsed)
    }
}
