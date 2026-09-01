import Foundation

/// Resolves the transcript file for an agent session.
///
/// This only locates files and reports activity; `TranscriptParser` parses
/// message content into render-ready chat messages.
enum SessionJSONLReader {
    static let projectsDirectory = URL.homeDirectory.appending(path: ".claude/projects")

    /// Claude Code encodes a project directory by replacing `/` and `.` with
    /// `-`, so `/Users/me/dev` becomes `-Users-me-dev` and a hidden directory
    /// yields a double dash (`…Notability/.claude/worktrees/x` →
    /// `-Users-…-Notability--claude-worktrees-x`). Worktree cwds therefore get
    /// their own directory, separate from the parent repo's.
    ///
    /// Only `/` and `.` are verified against real transcript directories.
    /// Prefer the hook payload's `transcript_path`, which is authoritative;
    /// this derivation is the fallback.
    static func encodedProjectDirectory(for path: String) -> String {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        let trimmed = standardized.count > 1 && standardized.hasSuffix("/")
            ? String(standardized.dropLast())
            : standardized
        return String(trimmed.map { $0 == "/" || $0 == "." ? "-" : $0 })
    }

    static func transcriptPath(workingDirectory: String, sessionID: String) -> String {
        projectsDirectory
            .appending(path: encodedProjectDirectory(for: workingDirectory))
            .appending(path: "\(sessionID).jsonl")
            .path
    }

    /// The hook payload carries `transcript_path` directly, which is
    /// authoritative; deriving it from the cwd is the fallback.
    static func resolveTranscriptPath(
        hookProvided: String?,
        workingDirectory: String?,
        sessionID: String?
    ) -> String? {
        if let hookProvided, !hookProvided.isEmpty { return hookProvided }
        guard let workingDirectory, let sessionID, !sessionID.isEmpty else { return nil }
        return transcriptPath(workingDirectory: workingDirectory, sessionID: sessionID)
    }

    /// Activity signal for when hooks misfire — a transcript being written
    /// means the agent is doing something.
    static func lastModified(atPath path: String) -> Date? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        return attributes[.modificationDate] as? Date
    }

    /// Claude Code writes its own generated session title into the transcript
    /// as `{"type":"ai-title","aiTitle":"…"}`, rewriting it as the
    /// conversation develops, so the last one is the current title. Nil means
    /// Claude has not titled the session yet — short sessions never get one.
    static func latestAITitle(atPath path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return latestAITitle(in: data)
    }

    static func latestAITitle(in data: Data) -> String? {
        let decoder = JSONDecoder()
        // A transcript is mostly line types Plume does not model, so every
        // line that fails to decode is skipped rather than treated as an error.
        for line in data.split(separator: UInt8(ascii: "\n")).reversed() {
            guard !line.isEmpty,
                  let entry = try? decoder.decode(TitleEntry.self, from: Data(line)),
                  entry.type == "ai-title",
                  let title = entry.aiTitle,
                  !title.isEmpty
            else { continue }
            return title
        }
        return nil
    }

    private struct TitleEntry: Decodable {
        let type: String?
        let aiTitle: String?
    }

    static func exists(atPath path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    /// Subagent transcripts live alongside the main one, in a directory
    /// named after it minus the `.jsonl` extension.
    static func subagentsDirectory(forTranscriptPath transcriptPath: String) -> String {
        (transcriptPath as NSString).deletingPathExtension + "/subagents"
    }

    /// The `agent-*.jsonl` transcripts under a session's subagents
    /// directory, sorted, or empty if the directory does not exist.
    static func subagentTranscriptPaths(forTranscriptPath transcriptPath: String) -> [String] {
        let directory = subagentsDirectory(forTranscriptPath: transcriptPath)
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return [] }
        return entries
            .filter { $0.hasPrefix("agent-") && $0.hasSuffix(".jsonl") }
            .sorted()
            .map { directory + "/" + $0 }
    }
}
