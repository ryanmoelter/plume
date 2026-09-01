import Foundation
import Testing

@testable import Plume

/// Parses every transcript on this machine, locking the parser against the
/// real corpus rather than fixtures. A Claude Code format change shows up
/// here first, as main transcripts that suddenly yield nothing.
struct RealTranscriptCorpusTests {
    /// A main transcript is one directly under a project directory; the
    /// `subagents/agent-*.jsonl` files beside it hold sidechain lines, which
    /// `TranscriptParser` skips by design.
    private func transcripts() -> (main: [URL], subagent: [URL]) {
        let files = FileManager.default.enumerator(
            at: SessionJSONLReader.projectsDirectory, includingPropertiesForKeys: nil
        )?
        .compactMap { $0 as? URL }
        .filter { $0.pathExtension == "jsonl" } ?? []

        return (
            files.filter { $0.deletingLastPathComponent().lastPathComponent != "subagents" },
            files.filter { $0.deletingLastPathComponent().lastPathComponent == "subagents" }
        )
    }

    @Test func mainTranscriptsYieldMessages() throws {
        let (main, _) = transcripts()
        try #require(!main.isEmpty, "no transcripts on this machine")

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
    @Test func subagentTranscriptsAreSkippedAsSidechains() throws {
        let (_, subagent) = transcripts()
        try #require(!subagent.isEmpty, "no subagent transcripts on this machine")

        let leaked = subagent.filter { url in
            guard let data = try? Data(contentsOf: url) else { return false }
            return !TranscriptParser.parse(data).messages.isEmpty
        }

        #expect(leaked.isEmpty, "\(leaked.count) subagent transcripts leaked into a main parse")
    }

    /// No real transcript may crash or hang the parser.
    /// No user message in the real corpus may open with an injected wrapper.
    /// This is the regression guard for the classifier: if Claude Code adds a
    /// new wrapper tag, or renames one, the content starts rendering as the
    /// user's own prose again and this fails.
    @Test func noInjectedContentRendersAsUserProse() throws {
        let (main, _) = transcripts()
        try #require(!main.isEmpty, "no transcripts on this machine")

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

    @Test func everyTranscriptParsesWithoutCrashing() throws {
        let (main, subagent) = transcripts()
        for url in main + subagent {
            guard let data = try? Data(contentsOf: url) else { continue }
            _ = TranscriptParser.parse(data)
        }
    }
}
