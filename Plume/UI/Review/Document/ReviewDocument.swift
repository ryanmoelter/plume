#if DEBUG
import Foundation

/// One row of the review document: every changed file, one after another.
nonisolated struct ReviewDocumentRow: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case fileHeader(DiffFileSummary, collapsed: Bool)
        case hunk(String)
        /// `spans` color the text; `wraps` is set for prose, which soft-wraps
        /// instead of scrolling sideways.
        case line(DiffLine, spans: [CodeSyntax.Span], wraps: Bool)
        case placeholder(ReviewFilePlaceholder)
        case comment(UUID)
    }

    /// What a row is across reloads, so a relist can tell an edited row from
    /// a moved one and the scroll can stay on the line the reader was at.
    enum Identity: Hashable, Sendable {
        case fileHeader(String)
        case hunk(String, String)
        case line(String, old: Int?, new: Int?, String)
        case placeholder(String)
        case comment(UUID)
    }

    let path: String
    let kind: Kind

    var identity: Identity {
        switch kind {
        case .fileHeader: .fileHeader(path)
        case .hunk(let header): .hunk(path, header)
        case .line(let line, _, _): .line(path, old: line.oldNumber, new: line.newNumber, line.text)
        case .placeholder: .placeholder(path)
        case .comment(let id): .comment(id)
        }
    }

    var isFileHeader: Bool {
        if case .fileHeader = kind { return true }
        return false
    }
}

/// What stands in for a file's lines.
nonisolated enum ReviewFilePlaceholder: Equatable, Sendable {
    /// Not loaded yet. Reserves about the room the lines will take.
    case pending(estimatedRows: Int)
    /// Over the line cap; nil when the file was too large to count.
    case tooLarge(changedLines: Int?)
    case binary
    case empty
    case failed(String)
}

/// A file's rows once loaded, built off the main actor.
nonisolated enum ReviewFileBody: Sendable {
    /// `columns` is the widest line in characters, a tab at its widest stop.
    case rows([ReviewDocumentRow], columns: Int)
    case placeholder(ReviewFilePlaceholder)
}

/// One file's rows in the document, header first.
nonisolated struct ReviewDocumentSegment: Equatable, Sendable {
    let path: String
    let rows: [ReviewDocumentRow]
    /// Zero unless the file shows code that scrolls sideways.
    let columns: Int
}

nonisolated enum ReviewDocument {
    /// Past this a line renders plain: it is a minified dump, not code to
    /// read, and the tokenize would dominate the load.
    static let maxHighlightedLength = 2_000

    static func wraps(_ path: String) -> Bool {
        ["md", "markdown"].contains((path as NSString).pathExtension.lowercased())
    }

    /// Rows for a hunk header and each line, highlighted. Runs off the main
    /// actor, once per load.
    static func body(for content: DiffFileContent, path: String) -> ReviewFileBody {
        switch content {
        case .binary: return .placeholder(.binary)
        case .empty: return .placeholder(.empty)
        case .tooLarge(let changedLines): return .placeholder(.tooLarge(changedLines: changedLines))
        case .text(let hunks):
            let wraps = wraps(path)
            let language = (path as NSString).pathExtension
            var rows: [ReviewDocumentRow] = []
            rows.reserveCapacity(hunks.reduce(0) { $0 + $1.lines.count + 1 })
            var columns = 0
            for hunk in hunks {
                rows.append(ReviewDocumentRow(path: path, kind: .hunk(hunk.header)))
                for line in hunk.lines {
                    let spans = line.text.utf16.count <= maxHighlightedLength
                        ? CodeSyntax.spans(for: line.text, language: language)
                        : []
                    rows.append(ReviewDocumentRow(path: path, kind: .line(line, spans: spans, wraps: wraps)))
                    if !wraps { columns = max(columns, Self.columns(of: line.text)) }
                }
            }
            return .rows(rows, columns: columns)
        }
    }

    static func columns(of text: String) -> Int {
        let tabs = text.utf8.reduce(0) { $1 == 0x09 ? $0 + 1 : $0 }
        return text.count + tabs * (tabWidth - 1)
    }

    static let tabWidth = 8

    /// About how many rows a file's diff takes, from its line counts alone:
    /// each changed line, plus a header and some context per hunk. An added
    /// or deleted file is one hunk with no context.
    static func estimatedRows(for file: DiffFileSummary) -> Int {
        let changed = file.changedLines
        guard changed > 0 else { return 1 }
        if file.kind == .added || file.kind == .deleted { return changed + 1 }
        let hunks = max(1, min(changed / 12, 50))
        return changed + hunks * 7
    }

    /// A file's rows: its header, then its lines or what stands in for them,
    /// with each comment's draft after the line it ends at.
    static func segment(
        file: DiffFileSummary,
        state: ReviewContentState?,
        collapsed: Bool,
        comments: [ReviewComment]
    ) -> ReviewDocumentSegment {
        let header = ReviewDocumentRow(path: file.path, kind: .fileHeader(file, collapsed: collapsed))
        guard !collapsed else { return ReviewDocumentSegment(path: file.path, rows: [header], columns: 0) }
        var rows = [header]
        var columns = 0
        switch state {
        case nil, .loading:
            rows.append(ReviewDocumentRow(path: file.path, kind: .placeholder(.pending(estimatedRows: estimatedRows(for: file)))))
        case .failed(let message):
            rows.append(ReviewDocumentRow(path: file.path, kind: .placeholder(.failed(message))))
        case .loaded(.placeholder(let placeholder), _):
            rows.append(ReviewDocumentRow(path: file.path, kind: .placeholder(placeholder)))
        case .loaded(.rows(let body, let bodyColumns), _):
            columns = bodyColumns
            let drafts = comments.filter { $0.path == file.path }
            if drafts.isEmpty {
                rows.append(contentsOf: body)
            } else {
                rows.reserveCapacity(body.count + drafts.count + 1)
                for row in body {
                    rows.append(row)
                    guard case .line(let line, _, _) = row.kind else { continue }
                    for draft in drafts where draft.endsAt(line) {
                        rows.append(ReviewDocumentRow(path: file.path, kind: .comment(draft.id)))
                    }
                }
            }
        }
        return ReviewDocumentSegment(path: file.path, rows: rows, columns: columns)
    }
}

/// The table edits that turn one document into the next. `removed` indexes
/// the old rows; `inserted` and `reloaded` index the new ones.
nonisolated struct ReviewDocumentChanges: Equatable, Sendable {
    var removed = IndexSet()
    var inserted = IndexSet()
    var reloaded = IndexSet()

    var isEmpty: Bool { removed.isEmpty && inserted.isEmpty && reloaded.isEmpty }

    /// Files pair up by path. Within a pair, the rows both ends share by
    /// identity stay, and the run between them is reloaded when it keeps
    /// its length or replaced when it doesn't. That is linear in the rows,
    /// which a general diff of a 10,000-line file is not, and a save
    /// changes one run.
    static func between(_ old: [ReviewDocumentSegment], _ new: [ReviewDocumentSegment]) -> ReviewDocumentChanges {
        var changes = ReviewDocumentChanges()
        let difference = new.map(\.path).difference(from: old.map(\.path))
        var removedSegments = Set<Int>()
        var insertedSegments = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removedSegments.insert(offset)
            case .insert(let offset, _, _): insertedSegments.insert(offset)
            }
        }
        var oldStarts: [Int] = []
        var start = 0
        for segment in old {
            oldStarts.append(start)
            start += segment.rows.count
        }
        var newStarts: [Int] = []
        start = 0
        for segment in new {
            newStarts.append(start)
            start += segment.rows.count
        }
        for index in removedSegments {
            changes.removed.insert(integersIn: oldStarts[index] ..< oldStarts[index] + old[index].rows.count)
        }
        for index in insertedSegments {
            changes.inserted.insert(integersIn: newStarts[index] ..< newStarts[index] + new[index].rows.count)
        }
        let keptOld = old.indices.filter { !removedSegments.contains($0) }
        let keptNew = new.indices.filter { !insertedSegments.contains($0) }
        for (oldIndex, newIndex) in zip(keptOld, keptNew) {
            changes.compare(old[oldIndex].rows, at: oldStarts[oldIndex], with: new[newIndex].rows, at: newStarts[newIndex])
        }
        return changes
    }

    private mutating func compare(_ old: [ReviewDocumentRow], at oldStart: Int, with new: [ReviewDocumentRow], at newStart: Int) {
        guard old != new else { return }
        let shorter = min(old.count, new.count)
        var prefix = 0
        while prefix < shorter, old[prefix].identity == new[prefix].identity {
            if old[prefix] != new[prefix] { reloaded.insert(newStart + prefix) }
            prefix += 1
        }
        var suffix = 0
        while suffix < shorter - prefix,
              old[old.count - 1 - suffix].identity == new[new.count - 1 - suffix].identity {
            if old[old.count - 1 - suffix] != new[new.count - 1 - suffix] {
                reloaded.insert(newStart + new.count - 1 - suffix)
            }
            suffix += 1
        }
        let oldMiddle = prefix ..< old.count - suffix
        let newMiddle = prefix ..< new.count - suffix
        if oldMiddle.count == newMiddle.count {
            for offset in 0 ..< newMiddle.count where old[oldMiddle.lowerBound + offset] != new[newMiddle.lowerBound + offset] {
                reloaded.insert(newStart + newMiddle.lowerBound + offset)
            }
        } else {
            removed.insert(integersIn: oldStart + oldMiddle.lowerBound ..< oldStart + oldMiddle.upperBound)
            inserted.insert(integersIn: newStart + newMiddle.lowerBound ..< newStart + newMiddle.upperBound)
        }
    }
}
#endif
