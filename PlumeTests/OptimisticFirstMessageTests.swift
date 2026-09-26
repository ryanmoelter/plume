import Foundation
import Testing

@testable import Plume

/// The rule that keeps an optimistic first message from double-rendering: it
/// shows until the transcript carries the same user prose, and never after.
struct OptimisticFirstMessageTests {
    private func userMessage(_ text: String, id: String = UUID().uuidString) -> ChatMessage {
        ChatMessage(id: id, role: .user, blocks: [.markdown(text)], timestamp: nil)
    }

    private func assistantMessage(_ text: String) -> ChatMessage {
        ChatMessage(id: UUID().uuidString, role: .assistant, blocks: [.markdown(text)], timestamp: nil)
    }

    @Test func pendingMessageRendersWhileTranscriptIsEmpty() {
        let pending = OptimisticFirstMessage(text: "hello there")
        let rendered = OptimisticChatReconciler.messages(transcript: [], pending: pending)

        #expect(rendered.count == 1)
        #expect(rendered.first?.role == .user)
        #expect(rendered.first?.prose == "hello there")
    }

    @Test func transcriptAloneRendersWithoutAPendingMessage() {
        let transcript = [userMessage("hello there"), assistantMessage("hi")]
        let rendered = OptimisticChatReconciler.messages(transcript: transcript, pending: nil)

        #expect(rendered.map(\.id) == transcript.map(\.id))
    }

    @Test func theRealLineReplacesThePendingCopyRatherThanJoiningIt() {
        let pending = OptimisticFirstMessage(text: "hello there")
        let transcript = [userMessage("hello there")]
        let rendered = OptimisticChatReconciler.messages(transcript: transcript, pending: pending)

        #expect(rendered.count == 1)
        #expect(rendered.first?.id == transcript[0].id)
        #expect(!rendered.contains { $0.id == OptimisticFirstMessage.messageID })
    }

    @Test func whitespaceDifferencesStillCountAsTheSameLine() {
        let pending = OptimisticFirstMessage(text: "  hello there\n")
        let rendered = OptimisticChatReconciler.messages(
            transcript: [userMessage("hello there")],
            pending: pending
        )

        #expect(rendered.count == 1)
    }

    @Test func anAssistantEchoDoesNotRetireThePendingMessage() {
        let pending = OptimisticFirstMessage(text: "hello there")
        let rendered = OptimisticChatReconciler.messages(
            transcript: [assistantMessage("hello there")],
            pending: pending
        )

        #expect(rendered.count == 2)
        #expect(rendered.last?.id == OptimisticFirstMessage.messageID)
    }

    @Test func thePendingMessageTrailsATranscriptThatHasNotCaughtUp() {
        let pending = OptimisticFirstMessage(text: "second question")
        let transcript = [userMessage("first question"), assistantMessage("an answer")]
        let rendered = OptimisticChatReconciler.messages(transcript: transcript, pending: pending)

        #expect(rendered.count == 3)
        #expect(rendered.last?.prose == "second question")
    }

    @Test func aFailureRendersAsANoticeBesideTheMessage() {
        let pending = OptimisticFirstMessage(
            text: "hello there",
            failure: ChatStartFailure(title: "claude not found", detail: "PATH", remedy: .installCLI)
        )
        let rendered = OptimisticChatReconciler.messages(transcript: [], pending: pending)

        #expect(rendered.count == 2)
        #expect(rendered.first?.role == .user)
        #expect(rendered.last?.role == .notice)
    }

    @Test func aFailedStartKeepsItsMessageEvenOnceTheTranscriptArrives() {
        let pending = OptimisticFirstMessage(
            text: "hello there",
            failure: ChatStartFailure(title: "claude not found", detail: nil, remedy: .installCLI)
        )

        #expect(!OptimisticChatReconciler.isSettled(
            transcript: [userMessage("hello there")],
            pending: pending
        ))
    }

    @Test func settlingReportsOnlyOnceTheLineLands() {
        let pending = OptimisticFirstMessage(text: "hello there")

        #expect(!OptimisticChatReconciler.isSettled(transcript: [], pending: pending))
        #expect(OptimisticChatReconciler.isSettled(
            transcript: [userMessage("hello there")],
            pending: pending
        ))
        #expect(!OptimisticChatReconciler.isSettled(transcript: [], pending: nil))
    }

    @Test func proseIgnoresNonMarkdownBlocks() {
        let message = ChatMessage(
            id: "x",
            role: .user,
            blocks: [.injected(.userMessage, text: "injected"), .markdown("typed")],
            timestamp: nil
        )

        #expect(message.prose == "typed")
    }

    /// A `!` command's first message is the CLI's bash-mode tags, which read
    /// as XML if they render as prose.
    @Test func aCommandRendersAsAShellLineRatherThanProse() {
        let text = """
        <bash-input>echo hi</bash-input>
        <bash-stdout>hi</bash-stdout><bash-stderr></bash-stderr>
        """
        let pending = OptimisticFirstMessage(text: text)
        #expect(pending.message.blocks == [.injected(.shellCommand(command: "echo hi"), text: text)])
    }

    @Test func aCommandSettlesOnceTheTranscriptCarriesIt() {
        let text = "<bash-input>echo hi</bash-input>"
        let pending = OptimisticFirstMessage(text: text)
        let arrived = ChatMessage(
            id: "1",
            role: .user,
            blocks: [.injected(.shellCommand(command: "echo hi"), text: text)],
            timestamp: nil
        )
        #expect(pending.isSettled(by: [arrived]))
    }

    /// A slash command as the first message is sent as plain typed text —
    /// "/review DROID-344" — but Claude Code, not Plume, expands it before
    /// writing the transcript line, so the pending copy never equals what
    /// comes back unless the settlement check reconstructs it the same way
    /// `InjectedContent`'s own marker does.
    @Test func aSlashCommandSettlesOnceTheTranscriptExpandsIt() {
        let pending = OptimisticFirstMessage(text: "/review DROID-344")
        let line = """
        {"type":"user","uuid":"u1","isSidechain":false,"message":{"role":"user","content":"<command-message>review is running…</command-message>\\n<command-name>/review</command-name>\\n<command-args>DROID-344</command-args>"}}
        """
        let arrived = TranscriptParser.parse(Data(line.utf8)).messages

        #expect(pending.isSettled(by: arrived))
    }

    /// A command with no arguments still needs the reconstruction: with none,
    /// the expanded line never equals the raw text, and the optimistic
    /// message lingers even once the real one has landed.
    @Test func aSlashCommandWithNoArgumentsStillSettles() {
        let pending = OptimisticFirstMessage(text: "/compact")
        let arrived = ChatMessage(
            id: "1",
            role: .user,
            blocks: [.injected(
                .slashCommand(name: "/compact"),
                text: "<command-name>/compact</command-name>\n<command-args></command-args>"
            )],
            timestamp: nil
        )
        #expect(pending.isSettled(by: [arrived]))
    }

    /// Typed args can run together with more than one space; the
    /// reconstruction always joins with exactly one, so the comparison has
    /// to collapse whitespace rather than compare it exactly.
    @Test func extraSpacesInTypedArgumentsStillSettle() {
        let pending = OptimisticFirstMessage(text: "/review   DROID-344")
        let arrived = ChatMessage(
            id: "1",
            role: .user,
            blocks: [.injected(
                .slashCommand(name: "/review", arguments: "DROID-344"),
                text: "<command-name>/review</command-name>\n<command-args>DROID-344</command-args>"
            )],
            timestamp: nil
        )
        #expect(pending.isSettled(by: [arrived]))
    }
}
