import Foundation
import Testing

/// Where a corpus test reads Claude Code's files from.
///
/// `fixtures` is an anonymized sample of real transcripts, subagent files and
/// plans, checked in under `Fixtures/Corpus` in the same layout as `~/.claude`,
/// so the corpus tests run on any machine. `thisMac` is the developer's own
/// `~/.claude`, the live corpus that catches a Claude Code format change first.
/// It is offered only where it holds files, so a fresh machine or CI runs the
/// fixtures alone.
nonisolated enum ClaudeCorpus: String, CaseIterable, Sendable, CustomTestStringConvertible {
    case fixtures
    case thisMac

    var root: URL {
        switch self {
        case .fixtures:
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .appending(path: "Fixtures/Corpus")
        case .thisMac:
            FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude")
        }
    }

    var projectsDirectory: URL { root.appending(path: "projects") }
    var plansDirectory: URL { root.appending(path: "plans") }

    var testDescription: String { rawValue }

    /// Files under `directory` with the given extension, recursively.
    static func files(in directory: URL, withExtension pathExtension: String) -> [URL] {
        FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == pathExtension } ?? []
    }

    /// The corpora holding at least one transcript. The fixtures always do,
    /// so a fixture that goes missing fails the run rather than vanishing.
    static let withTranscripts: [ClaudeCorpus] = allCases.filter {
        $0 == .fixtures || containsFile(in: $0.projectsDirectory, withExtension: "jsonl")
    }

    /// The corpora holding at least one plan file.
    static let withPlans: [ClaudeCorpus] = allCases.filter {
        $0 == .fixtures || containsFile(in: $0.plansDirectory, withExtension: "md")
    }

    /// Stops at the first match, since `~/.claude/projects` can hold
    /// thousands of files and this runs while tests are being discovered.
    private static func containsFile(in directory: URL, withExtension pathExtension: String) -> Bool {
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: nil
        ) else { return false }
        for case let url as URL in enumerator where url.pathExtension == pathExtension {
            return true
        }
        return false
    }
}
