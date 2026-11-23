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
        let contents = planFiles().compactMap { url -> (name: String, text: String)? in
            guard let text = try? String(contentsOf: url, encoding: .utf8),
                !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            return (url.lastPathComponent, text)
        }
        try #require(!contents.isEmpty, "no non-empty plan files on this machine")

        for (name, text) in contents {
            #expect(!MarkdownBlock.parse(text).isEmpty, "\(name) parsed into no blocks")
        }
    }
}
