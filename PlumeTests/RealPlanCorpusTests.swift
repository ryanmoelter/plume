import Foundation
import Testing

@testable import Plume

/// Parses every plan file in a corpus through `MarkdownBlock`, the same way
/// `RealTranscriptCorpusTests` locks the transcript parser against real files
/// rather than hand-written ones: the anonymized fixture sample everywhere,
/// and this machine's `~/.claude/plans` too where it has any.
struct RealPlanCorpusTests {
    @Test(arguments: ClaudeCorpus.withPlans)
    func everyPlanFileParsesIntoAtLeastOneBlock(in corpus: ClaudeCorpus) throws {
        let files = ClaudeCorpus.files(in: corpus.plansDirectory, withExtension: "md")
        try #require(!files.isEmpty, "no plan files in \(corpus)")

        for url in files {
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let blocks = MarkdownBlock.parse(content)
            #expect(!blocks.isEmpty, "\(url.lastPathComponent) parsed into no blocks")
        }
    }
}
