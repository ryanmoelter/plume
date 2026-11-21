import Foundation
import Testing

@testable import Plume

/// Parses every transcript in a corpus of real ones, locking the parser
/// against what Claude Code actually writes. Each test runs on the anonymized
/// fixture sample everywhere, and on this machine's `~/.claude` too where it
/// has transcripts. A Claude Code format change shows up there first, as main
/// transcripts that suddenly yield nothing.
struct RealTranscriptCorpusTests {
    /// A main transcript is one directly under a project directory; the
    /// `subagents/agent-*.jsonl` files beside it hold sidechain lines, which
    /// `TranscriptParser` skips by design.
    private func transcripts(in corpus: ClaudeCorpus) -> (main: [URL], subagent: [URL]) {
        let files = ClaudeCorpus.files(in: corpus.projectsDirectory, withExtension: "jsonl")

        return (
            files.filter { $0.deletingLastPathComponent().lastPathComponent != "subagents" },
            files.filter { $0.deletingLastPathComponent().lastPathComponent == "subagents" }
        )
    }

    @Test(arguments: ClaudeCorpus.withTranscripts)
    func mainTranscriptsYieldMessages(in corpus: ClaudeCorpus) throws {
        let (main, _) = transcripts(in: corpus)
        try #require(!main.isEmpty, "no transcripts in \(corpus)")

        let withMessages = main.count { url in
            guard let data = try? Data(contentsOf: url) else { return false }
            return !TranscriptParser.parse(data).messages.isEmpty
        }

        // A handful of transcripts are metadata-only stubs — a session that
        // opened and never exchanged a message. The rest must parse.
        #expect(
            withMessages > main.count * 3 / 4,
            "only \(withMessages) of \(main.count) main transcripts yielded messages"
        )
    }

    /// Every subagent file is sidechain, which the main parser drops. Reading
    /// one as a main transcript therefore yields nothing — the property that
    /// keeps subagent turns out of the main conversation.
    @Test(arguments: ClaudeCorpus.withTranscripts)
    func subagentTranscriptsAreSkippedAsSidechains(in corpus: ClaudeCorpus) throws {
        let (_, subagent) = transcripts(in: corpus)
        try #require(!subagent.isEmpty, "no subagent transcripts in \(corpus)")

        let leaked = subagent.filter { url in
            guard let data = try? Data(contentsOf: url) else { return false }
            return !TranscriptParser.parse(data).messages.isEmpty
        }

        #expect(leaked.isEmpty, "\(leaked.count) subagent transcripts leaked into a main parse")
    }

    /// No user message in the real corpus may open with an injected wrapper.
    /// This is the regression guard for the classifier: if Claude Code adds a
    /// new wrapper tag, or renames one, the content starts rendering as the
    /// user's own prose again and this fails.
    @Test(arguments: ClaudeCorpus.withTranscripts)
    func noInjectedContentRendersAsUserProse(in corpus: ClaudeCorpus) throws {
        let (main, _) = transcripts(in: corpus)
        try #require(!main.isEmpty, "no transcripts in \(corpus)")

        var leaked: [String] = []
        for url in main {
            guard let data = try? Data(contentsOf: url) else { continue }
            for message in TranscriptParser.parse(data).messages where message.role == .user {
                for block in message.blocks {
                    guard case .markdown(let text) = block else { continue }
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.hasPrefix("<") || trimmed.hasPrefix("Base directory for this skill:")
                        || trimmed.hasPrefix("[Request interrupted") {
                        leaked.append("\(url.lastPathComponent): \(trimmed.prefix(60))")
                    }
                }
            }
        }

        #expect(leaked.isEmpty, "injected content rendered as user prose:\n\(leaked.prefix(5).joined(separator: "\n"))")
    }

    /// Almost every real `ExitPlanMode` and `AskUserQuestion` must decode to
    /// a structured payload. A payload-shape change in Claude Code shows up
    /// as these falling back to raw JSON.
    @Test(arguments: ClaudeCorpus.withTranscripts)
    func interactiveToolCallsDecodeAcrossTheCorpus(in corpus: ClaudeCorpus) throws {
        let (main, _) = transcripts(in: corpus)
        try #require(!main.isEmpty, "no transcripts in \(corpus)")

        var total = 0
        var decoded = 0
        for url in main {
            guard let data = try? Data(contentsOf: url) else { continue }
            for message in TranscriptParser.parse(data).messages {
                for block in message.blocks {
                    guard case .toolCall(let call) = block,
                          call.name == "ExitPlanMode" || call.name == "AskUserQuestion"
                    else { continue }
                    total += 1
                    if call.interactive != nil { decoded += 1 }
                }
            }
        }

        try #require(total > 0, "no interactive tool calls in the corpus")
        // One known ExitPlanMode carries an empty input and correctly falls
        // back, so this is a high bar rather than a total.
        #expect(
            decoded > total * 9 / 10,
            "only \(decoded) of \(total) interactive tool calls decoded"
        )
    }

    /// No real transcript may crash or hang the parser.
    @Test(arguments: ClaudeCorpus.withTranscripts)
    func everyTranscriptParsesWithoutCrashing(in corpus: ClaudeCorpus) throws {
        let (main, subagent) = transcripts(in: corpus)
        for url in main + subagent {
            guard let data = try? Data(contentsOf: url) else { continue }
            _ = TranscriptParser.parse(data)
        }
    }

    /// The resume picker must not degrade into a list of bare UUIDs. A
    /// session whose only user line is a command's own output genuinely has
    /// nothing to be called, so the guard is a proportion rather than a
    /// certainty — a format change shows up as the labelled share collapsing.
    @Test(arguments: ClaudeCorpus.withTranscripts)
    func nearlyEverySessionWithContentHasALabel(in corpus: ClaudeCorpus) throws {
        let (main, _) = transcripts(in: corpus)
        try #require(!main.isEmpty, "no transcripts in \(corpus)")

        let substantial = main.filter { url in
            guard let data = try? Data(contentsOf: url) else { return false }
            return !TranscriptParser.parse(data).messages.isEmpty
        }
        try #require(!substantial.isEmpty)

        let unlabelled = substantial.filter { url in
            let session = SessionJSONLReader.storedSession(
                atTranscriptPath: url.path,
                workingDirectory: url.deletingLastPathComponent().path
            )
            guard let session else { return true }
            return session.title == nil && session.firstUserMessage == nil
        }

        // Cross-multiplied rather than `< count / 20`: integer division put the bound on a whole
        // session, so a corpus of 51 rejected 2 unlabelled (3.9%) for tying it.
        #expect(
            unlabelled.count * 20 <= substantial.count,
            "\(unlabelled.count) of \(substantial.count) sessions would list as a bare UUID"
        )
    }
}
