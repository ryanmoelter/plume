import Foundation
import Testing

@testable import Plume

/// Parses every plan file on this machine through `MarkdownBlock`, the same
/// way `RealTranscriptCorpusTests` locks the transcript parser against the
/// real corpus rather than fixtures.
struct RealPlanCorpusTests {
    private var plansDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/plans")
    }

    private func planFiles() -> [URL] {
        FileManager.default.enumerator(at: plansDirectory, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "md" } ?? []
    }

    @Test func everyPlanFileParsesIntoAtLeastOneBlock() throws {
        let files = planFiles()
        try #require(!files.isEmpty, "no plan files on this machine")

        for url in files {
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let blocks = MarkdownBlock.parse(content)
            #expect(!blocks.isEmpty, "\(url.lastPathComponent) parsed into no blocks")
        }
    }
}
