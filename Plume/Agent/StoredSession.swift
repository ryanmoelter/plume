import Foundation

/// A past `claude` conversation on disk, as the resume picker shows it.
nonisolated struct StoredSession: Identifiable, Hashable, Sendable {
    var id: String { sessionID }
    let sessionID: String
    let transcriptPath: String
    /// The directory this session ran in. Resuming it from a tab whose
    /// directory differs runs it in the tab's, not this one.
    let workingDirectory: String
    let title: String?
    let firstUserMessage: String?
    let lastModified: Date

    /// What the picker shows. The session ID is the last resort: a transcript
    /// too short to have been titled may also have no prose in it.
    var displayTitle: String {
        if let title, !title.isEmpty { return title }
        if let firstUserMessage, !firstUserMessage.isEmpty { return firstUserMessage }
        return String(sessionID.prefix(8))
    }
}

extension SessionJSONLReader {
    /// Transcripts Claude Code has written for `workingDirectory`, newest
    /// first.
    ///
    /// Only files directly in the directory are sessions; the `subagents`
    /// subdirectory beside each one holds sidechains, which cannot be
    /// resumed. Empty files are skipped — Claude Code leaves them behind for
    /// sessions that never produced a line.
    nonisolated static func storedSessions(inDirectory workingDirectory: String) -> [StoredSession] {
        let directory = projectsDirectory.appending(path: encodedProjectDirectory(for: workingDirectory))
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }

        return names
            .filter { $0.hasSuffix(".jsonl") }
            .compactMap { name in
                storedSession(
                    atTranscriptPath: directory.appending(path: name).path,
                    workingDirectory: workingDirectory
                )
            }
            .sorted { $0.lastModified > $1.lastModified }
    }

    nonisolated static func storedSession(atTranscriptPath path: String, workingDirectory: String) -> StoredSession? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? Int, size > 0,
              let modified = attributes[.modificationDate] as? Date,
              // Mapped rather than read: labelling a directory touches every
              // transcript in it, and the largest run to tens of megabytes.
              let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
        else { return nil }

        return StoredSession(
            sessionID: (path as NSString).lastPathComponent.replacingOccurrences(of: ".jsonl", with: ""),
            transcriptPath: path,
            workingDirectory: workingDirectory,
            title: latestAITitle(in: data.suffix(titleScanLimit)),
            firstUserMessage: firstUserMessage(in: data),
            lastModified: modified
        )
    }

    /// How a conversation opened, for a session Claude never titled.
    ///
    /// Prose wins, but a session begun with a slash command has none — the
    /// command *is* what the user asked for, and everything after it is tool
    /// results — so its name is the label rather than nothing. Other injected
    /// lines (a skill's body, a command's output) name no intent and are
    /// skipped.
    ///
    /// Scans forward only as far as `firstMessageScanLimit`, since the picker
    /// reads every transcript in a directory and they run to megabytes.
    nonisolated static func firstUserMessage(in data: Data, limit: Int = firstMessageScanLimit) -> String? {
        let decoder = JSONDecoder()
        var slashCommand: String?

        for line in data.prefix(limit).split(separator: UInt8(ascii: "\n")) {
            guard !line.isEmpty,
                  let entry = try? decoder.decode(TranscriptEntry.self, from: Data(line)),
                  entry.type == "user",
                  !entry.isSidechain,
                  let blocks = entry.message?.content?.blocks
            else { continue }

            let text = blocks.compactMap { block -> String? in
                if case .text(let value) = block { return value }
                return nil
            }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            switch InjectedContent.classify(text: text, isMeta: entry.isMeta) {
            case .userMessage:
                return shortenedOpeningLine(text)
            case .pastedContent:
                return shortenedOpeningLine(InjectedContent.pastedContent.bodyText(text))
            case .slashCommand(let name, _) where slashCommand == nil:
                slashCommand = name
            default:
                continue
            }
        }
        return slashCommand
    }

    /// A prefix generous enough to hold the opening exchange of every
    /// transcript in the corpus, without reading a 4 MB file to label it.
    nonisolated static let firstMessageScanLimit = 256 * 1024

    /// Claude rewrites `ai-title` as the conversation develops, so the
    /// current one is always near the end — within 40 KB of it in every
    /// transcript on this machine, the largest of which is 28 MB.
    nonisolated static let titleScanLimit = 256 * 1024

    /// Shortens an opening user message for use as a fallback title: the
    /// first non-empty line, whitespace collapsed, truncated at a word
    /// boundary. A title names a conversation at a glance; a multi-paragraph
    /// opener read in full is a wall of text everywhere this stands in for
    /// one, whether that's a tab waiting on its real title or a past session
    /// in the resume picker.
    nonisolated static func shortenedOpeningLine(_ text: String, maximum: Int = 60) -> String {
        let firstLine = text.components(separatedBy: .newlines)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        let collapsed = firstLine
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard collapsed.count > maximum else { return collapsed }

        let cutIndex = collapsed.index(collapsed.startIndex, offsetBy: maximum)
        let truncated = String(collapsed[..<cutIndex])
        // A word that ends exactly at the limit needs no further cutting.
        guard !collapsed[cutIndex].isWhitespace else { return truncated + "…" }

        // A word boundary far from the limit would throw away most of the
        // prefix, so a short word ahead of one long unbroken run hard-cuts
        // instead of shrinking to almost nothing.
        guard let lastSpace = truncated.lastIndex(of: " "),
              truncated.distance(from: truncated.startIndex, to: lastSpace) * 2 >= maximum
        else { return truncated + "…" }
        return String(truncated[..<lastSpace]) + "…"
    }
}
