import Foundation
import Testing

@testable import Plume

/// Feeds growing prefixes of every real transcript through one long-lived
/// `ChatPieceCache` and checks each build against a fresh cache, locking the
/// per-message memo against real transcripts: the anonymized sample in
/// `Fixtures/Corpus` everywhere, and this machine's `~/.claude` where it has any.
@MainActor
struct ChatPieceCacheCorpusTests {
    /// Each file is read only this far, cut back to its last whole line,
    /// which keeps the suite to seconds on a corpus of hundreds of megabytes.
    private static let bytesPerFile = 1 << 20
    /// Only the largest files are compared, since every step builds the
    /// prefix twice from scratch.
    private static let fileLimit = 40
    private static let prefixFractions = [0.3, 0.6, 0.8, 0.95, 1.0]

    private func mainTranscripts(in corpus: ClaudeCorpus) -> [URL] {
        let files = FileManager.default.enumerator(
            at: corpus.projectsDirectory, includingPropertiesForKeys: [.fileSizeKey]
        )?
        .compactMap { $0 as? URL }
        .filter { $0.pathExtension == "jsonl" && $0.deletingLastPathComponent().lastPathComponent != "subagents" } ?? []
        let sized = files.map { ($0, (try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        return sized.sorted { ($0.1, $0.0.path) > ($1.1, $1.0.path) }.prefix(Self.fileLimit).map(\.0)
    }

    @Test(arguments: ClaudeCorpus.withTranscripts)
    func growingPrefixesMatchAFreshCache(in corpus: ClaudeCorpus) throws {
        let main = mainTranscripts(in: corpus)
        try #require(!main.isEmpty, "no transcripts in \(corpus)")

        let base = URL(fileURLWithPath: NSHomeDirectory())
        let dimensions = Dimensions(bodySize: 13)
        var mismatches: [String] = []
        var compared = 0
        for url in main {
            guard let handle = try? FileHandle(forReadingFrom: url),
                  let data = try? handle.read(upToCount: Self.bytesPerFile),
                  !data.isEmpty
            else { continue }
            try? handle.close()
            let end = data.lastIndex(of: UInt8(ascii: "\n")).map { $0 + 1 } ?? data.count
            let messages = TranscriptParser.parse(Data(data.prefix(end))).messages
            guard !messages.isEmpty else { continue }

            var steps = Self.prefixFractions.map { fraction in
                (count: max(1, Int(Double(messages.count) * fraction)), status: TaskStatus.working)
            }
            steps.append((messages.count, .awaitingReply))
            steps.append((messages.count, .questionAsked))

            let cache = ChatPieceCache()
            // Each step titles the references the step before it found, so
            // titles arrive for links in messages the memo already holds.
            var titles: [ReferenceTarget: String] = [:]
            var revision = 0
            for (count, status) in steps {
                var inputs = ChatPieceCacheIncrementalTests.Inputs(messages: Array(messages.prefix(count)))
                inputs.status = status
                inputs.dimensions = dimensions
                inputs.linkBase = base
                inputs.revision = revision
                inputs.titles = titles
                let pieces = ChatPieceCacheIncrementalTests.build(cache, inputs)
                let fresh = ChatPieceCache()
                let expected = ChatPieceCacheIncrementalTests.build(fresh, inputs)
                compared += 1

                var problems: [String] = []
                if pieces != expected { problems.append("pieces") }
                if cache.referenceTargets != fresh.referenceTargets { problems.append("reference targets") }
                if cache.outline != fresh.outline { problems.append("outline") }
                let found = cache.referenceTargets.filter { target in
                    if case .artifact = target { return false }
                    return titles[target] == nil
                }
                if !found.isEmpty {
                    for target in found { titles[target] = "Title \(titles.count)" }
                    revision += 1
                }
                if !problems.isEmpty {
                    mismatches.append("\(url.lastPathComponent) at \(count) (\(status)): \(problems.joined(separator: ", "))")
                }
            }
        }

        try #require(compared > 0)
        #expect(mismatches.isEmpty, "\(mismatches.count) of \(compared) builds differ:\n\(mismatches.prefix(5).joined(separator: "\n"))")
    }
}
