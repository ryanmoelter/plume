import Foundation
import Testing

@testable import Plume

/// Folds every main transcript in a corpus in pieces and checks each piece's
/// result against a parse of the same bytes from scratch, locking the
/// incremental read against real transcripts: the anonymized sample in
/// `Fixtures/Corpus` everywhere, and this machine's `~/.claude` where it has any.
struct TranscriptFoldCorpusTests {
    /// Each file is read only this far, which keeps the suite to seconds on
    /// a corpus of hundreds of megabytes. The cut usually lands mid-line,
    /// which the fold must handle anyway.
    private static let bytesPerFile = 1 << 20
    /// Where each piece ends, as a fraction of the bytes read: either just
    /// after the next newline, or wherever the fraction falls, which is
    /// usually mid-line.
    private static let splits: [(fraction: Double, atLineBoundary: Bool)] = [
        (0.2, true), (0.45, false), (0.7, true), (1.0, false),
    ]
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func mainTranscripts(in corpus: ClaudeCorpus) -> [URL] {
        let files = FileManager.default.enumerator(
            at: corpus.projectsDirectory, includingPropertiesForKeys: nil
        )?
        .compactMap { $0 as? URL }
        .filter { $0.pathExtension == "jsonl" } ?? []
        return files.filter { $0.deletingLastPathComponent().lastPathComponent != "subagents" }
    }

    @Test(arguments: ClaudeCorpus.withTranscripts)
    func foldingInPiecesMatchesAFreshParseOfEachPrefix(in corpus: ClaudeCorpus) throws {
        let main = mainTranscripts(in: corpus)
        try #require(!main.isEmpty, "no transcripts in \(corpus)")

        var mismatches: [String] = []
        var compared = 0
        for url in main {
            guard let handle = try? FileHandle(forReadingFrom: url),
                  let data = try? handle.read(upToCount: Self.bytesPerFile),
                  !data.isEmpty
            else { continue }
            try? handle.close()

            var fold = TranscriptFold()
            for (fraction, atLineBoundary) in Self.splits {
                var end = Int(Double(data.count) * fraction)
                if atLineBoundary {
                    end = data[end...].firstIndex(of: UInt8(ascii: "\n")).map { $0 + 1 } ?? data.count
                }
                guard end >= Int(fold.consumed) else { continue }
                let snapshot = fold.append(data[Int(fold.consumed)..<end], now: Self.now)
                let prefix = Data(data.prefix(end))
                let entries = Array(TranscriptParser.decodedEntries(in: prefix))
                let knownIDs = Self.knownIDs(in: entries)
                compared += 1

                var problems: [String] = []
                if Self.comparable(snapshot.transcript, knownIDs: knownIDs)
                    != Self.comparable(TranscriptParser.parse(entries: entries), knownIDs: knownIDs) {
                    problems.append("transcript")
                }
                var backgroundTasks = BackgroundTaskScanner.State()
                var spawnResults = SubagentSpawnResults()
                var spawns = SubagentSpawnScanner.State()
                for entry in entries {
                    backgroundTasks.consume(entry, now: Self.now)
                    spawnResults.consume(entry)
                    spawns.consume(entry)
                }
                if snapshot.backgroundTasks != backgroundTasks.inFlight { problems.append("background tasks") }
                if snapshot.spawnResults != spawnResults { problems.append("spawn results") }
                if snapshot.spawnDescriptors != spawns.descriptors { problems.append("spawn descriptors") }
                if !problems.isEmpty {
                    mismatches.append("\(url.lastPathComponent) at \(end): \(problems.joined(separator: ", "))")
                }
            }
        }

        try #require(compared > 0)
        #expect(mismatches.isEmpty, "\(mismatches.count) of \(compared) prefixes differ:\n\(mismatches.prefix(5).joined(separator: "\n"))")
    }

    /// Every id a parse can give a message without inventing one.
    private static func knownIDs(in entries: [TranscriptEntry]) -> Set<String> {
        var ids = Set<String>()
        for entry in entries {
            if let uuid = entry.uuid { ids.insert(uuid) }
            if let id = entry.message?.id { ids.insert(id) }
        }
        return ids
    }

    /// A message with neither a row uuid nor an API id gets a fresh UUID on
    /// every parse, so two parses agree only once those are blanked.
    private static func comparable(_ transcript: Transcript, knownIDs: Set<String>) -> Transcript {
        func blanked(_ message: ChatMessage) -> ChatMessage {
            guard !knownIDs.contains(message.id) else { return message }
            var copy = ChatMessage(id: "generated", role: message.role, blocks: message.blocks, timestamp: message.timestamp)
            copy.isLive = message.isLive
            return copy
        }
        var copy = transcript
        copy.messages = transcript.messages.map(blanked)
        copy.abandonedBranches = transcript.abandonedBranches.mapValues { $0.map(blanked) }
        return copy
    }
}
