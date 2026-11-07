import Foundation

/// Parses the `-z` file listings and the single-file patches `GitDiffEngine`
/// asks `git diff` for.
nonisolated enum GitDiffParser {
    struct NameStatus: Equatable {
        let status: Character
        let path: String
        let oldPath: String?
    }

    struct LineCounts: Equatable {
        /// Nil for a binary file, which `--numstat` reports as `-`.
        let added: Int?
        let removed: Int?
    }

    /// Parses `git diff -z --name-status`. A rename or copy carries a score
    /// (`R087`) and two paths, old then new.
    static func nameStatus(_ output: String) -> [NameStatus] {
        var tokens = output.split(separator: "\0", omittingEmptySubsequences: false).makeIterator()
        var entries: [NameStatus] = []
        while let token = tokens.next() {
            guard let status = token.first else { continue }
            guard let first = tokens.next() else { break }
            if status == "R" || status == "C" {
                guard let second = tokens.next() else { break }
                entries.append(NameStatus(status: status, path: String(second), oldPath: String(first)))
            } else {
                entries.append(NameStatus(status: status, path: String(first), oldPath: nil))
            }
        }
        return entries
    }

    /// Parses `git diff -z --numstat`, keyed by the new path. A rename leaves
    /// the path field empty and puts old and new paths in the next two fields.
    static func numstat(_ output: String) -> [String: LineCounts] {
        var tokens = output.split(separator: "\0", omittingEmptySubsequences: false).makeIterator()
        var counts: [String: LineCounts] = [:]
        while let token = tokens.next() {
            let fields = token.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3 else { continue }
            let entry = LineCounts(added: Int(fields[0]), removed: Int(fields[1]))
            if fields[2].isEmpty {
                guard tokens.next() != nil, let newPath = tokens.next() else { break }
                counts[String(newPath)] = entry
            } else {
                counts[String(fields[2])] = entry
            }
        }
        return counts
    }

    /// Parses `git diff -z --raw --numstat`, which prints every raw record
    /// and then every numstat record. Read positionally, so a path that starts
    /// with `:` or holds a tab is never taken for a record.
    static func rawAndNumstat(_ output: String) -> (nameStatus: [NameStatus], numstat: [String: LineCounts]) {
        var tokens = output.split(separator: "\0", omittingEmptySubsequences: false).makeIterator()
        var entries: [NameStatus] = []
        var counts: [String: LineCounts] = [:]
        while let token = tokens.next() {
            if token.hasPrefix(":") {
                guard let status = token.split(separator: " ").last?.first,
                      let first = tokens.next()
                else { break }
                if status == "R" || status == "C" {
                    guard let second = tokens.next() else { break }
                    entries.append(NameStatus(status: status, path: String(second), oldPath: String(first)))
                } else {
                    entries.append(NameStatus(status: status, path: String(first), oldPath: nil))
                }
                continue
            }
            let fields = token.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3 else { continue }
            let entry = LineCounts(added: Int(fields[0]), removed: Int(fields[1]))
            if fields[2].isEmpty {
                guard tokens.next() != nil, let newPath = tokens.next() else { break }
                counts[String(newPath)] = entry
            } else {
                counts[String(fields[2])] = entry
            }
        }
        return (entries, counts)
    }

    static func summaries(nameStatus: [NameStatus], numstat: [String: LineCounts]) -> [DiffFileSummary] {
        nameStatus.map { entry in
            let counts = numstat[entry.path]
            let kind: DiffChangeKind = switch entry.status {
            case "A", "C": .added
            case "D": .deleted
            case "R": .renamed
            default: .modified
            }
            return DiffFileSummary(
                path: entry.path,
                oldPath: entry.status == "R" ? entry.oldPath : nil,
                kind: kind,
                isBinary: counts != nil && counts?.added == nil,
                addedLines: counts?.added ?? 0,
                removedLines: counts?.removed ?? 0
            )
        }
    }

    /// Parses one file's unified diff into hunks with line numbers.
    ///
    /// Each hunk is read for exactly the line counts its header declares, so a
    /// content line that happens to start with `diff --git` or `@@` is never
    /// mistaken for a header.
    static func patch(_ patch: String) -> DiffFileContent {
        var hunks: [DiffHunk] = []
        var current: DiffHunk?
        var oldLine = 0
        var newLine = 0
        var oldRemaining = 0
        var newRemaining = 0

        func finish() {
            if let hunk = current { hunks.append(hunk) }
            current = nil
        }

        // Split on scalars: as a `Character`, `\r\n` is one grapheme, so a
        // CRLF file would never split at all.
        for raw in patch.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = Substring(raw)
            if current != nil, oldRemaining > 0 || newRemaining > 0 {
                let marker = line.first
                // A CRLF file's `\r` would otherwise draw as a stray glyph.
                var text = line.isEmpty ? "" : String(line.dropFirst())
                if text.hasSuffix("\r") { text.removeLast() }
                switch marker {
                case "+":
                    current?.lines.append(DiffLine(kind: .added, text: text, oldNumber: nil, newNumber: newLine))
                    newLine += 1
                    newRemaining -= 1
                case "-":
                    current?.lines.append(DiffLine(kind: .removed, text: text, oldNumber: oldLine, newNumber: nil))
                    oldLine += 1
                    oldRemaining -= 1
                case "\\":
                    markMissingNewline(in: &current)
                default:
                    // A blank line here is a context line whose leading space
                    // some tool stripped.
                    current?.lines.append(DiffLine(kind: .context, text: text, oldNumber: oldLine, newNumber: newLine))
                    oldLine += 1
                    newLine += 1
                    oldRemaining -= 1
                    newRemaining -= 1
                }
                continue
            }

            if line.hasPrefix("\\"), current != nil {
                markMissingNewline(in: &current)
            } else if line.hasPrefix("@@ "), let header = hunkHeader(line) {
                finish()
                current = DiffHunk(
                    header: String(line),
                    oldStart: header.oldStart,
                    oldCount: header.oldCount,
                    newStart: header.newStart,
                    newCount: header.newCount,
                    lines: []
                )
                oldLine = header.oldStart
                newLine = header.newStart
                oldRemaining = header.oldCount
                newRemaining = header.newCount
            } else if hunks.isEmpty, current == nil,
                      line.hasPrefix("Binary files ") || line.hasPrefix("GIT binary patch") {
                return .binary
            }
        }
        finish()
        return hunks.isEmpty ? .empty : .text(hunks)
    }

    private static func markMissingNewline(in hunk: inout DiffHunk?) {
        guard var lines = hunk?.lines, !lines.isEmpty else { return }
        lines[lines.count - 1].missingNewline = true
        hunk?.lines = lines
    }

    struct HunkHeader: Equatable {
        let oldStart: Int
        let oldCount: Int
        let newStart: Int
        let newCount: Int
    }

    /// `@@ -a[,b] +c[,d] @@ …`, where an omitted count means 1.
    static func hunkHeader(_ line: Substring) -> HunkHeader? {
        let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
        guard parts.count >= 3, parts[0] == "@@",
              parts[1].hasPrefix("-"), parts[2].hasPrefix("+"),
              let old = range(parts[1].dropFirst()),
              let new = range(parts[2].dropFirst())
        else { return nil }
        return HunkHeader(oldStart: old.start, oldCount: old.count, newStart: new.start, newCount: new.count)
    }

    private static func range(_ text: Substring) -> (start: Int, count: Int)? {
        let pieces = text.split(separator: ",", omittingEmptySubsequences: false)
        guard let start = Int(pieces[0]) else { return nil }
        guard pieces.count > 1 else { return (start, 1) }
        guard pieces.count == 2, let count = Int(pieces[1]) else { return nil }
        return (start, count)
    }
}
