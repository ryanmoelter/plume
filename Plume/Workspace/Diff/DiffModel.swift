import Foundation

nonisolated enum DiffChangeKind: String, Hashable, Sendable {
    case added
    case modified
    case deleted
    case renamed

    var badge: String {
        switch self {
        case .added: "A"
        case .modified: "M"
        case .deleted: "D"
        case .renamed: "R"
        }
    }
}

/// One file in a range's file list. Paths are relative to the repository root.
nonisolated struct DiffFileSummary: Hashable, Sendable, Identifiable {
    /// Where the new side of the file comes from, which decides how its diff
    /// is loaded.
    enum Origin: Hashable, Sendable {
        case tracked
        case untracked
        /// Untracked on disk but present at the base, as after
        /// `git rm --cached`: it diffs against the base's copy.
        case untrackedOverBase
    }

    let path: String
    /// Set only for a rename.
    let oldPath: String?
    let kind: DiffChangeKind
    let isBinary: Bool
    let addedLines: Int
    let removedLines: Int
    let origin: Origin
    /// The file was too large to count, so its line counts are zero.
    let isUncounted: Bool

    var id: String { path }

    init(
        path: String,
        oldPath: String? = nil,
        kind: DiffChangeKind,
        isBinary: Bool = false,
        addedLines: Int = 0,
        removedLines: Int = 0,
        origin: Origin = .tracked,
        isUncounted: Bool = false
    ) {
        self.path = path
        self.oldPath = oldPath
        self.kind = kind
        self.isBinary = isBinary
        self.addedLines = addedLines
        self.removedLines = removedLines
        self.origin = origin
        self.isUncounted = isUncounted
    }

    var isUntracked: Bool { origin != .tracked }

    var changedLines: Int { addedLines + removedLines }
}

nonisolated struct DiffLine: Hashable, Sendable {
    let kind: FileDiff.LineKind
    let text: String
    let oldNumber: Int?
    let newNumber: Int?
    /// The line is the last in its file and has no trailing newline.
    var missingNewline = false
}

nonisolated struct DiffHunk: Hashable, Sendable {
    /// The whole `@@ … @@` line, including any section heading after it.
    let header: String
    let oldStart: Int
    let oldCount: Int
    let newStart: Int
    let newCount: Int
    var lines: [DiffLine]
}

nonisolated enum DiffFileContent: Hashable, Sendable {
    case text([DiffHunk])
    case binary
    /// Not loaded, because the change exceeds the line cap. Nil when the
    /// file was too large to count at all.
    case tooLarge(changedLines: Int?)
    /// A change with no line content, like a mode change or an empty file.
    case empty

    var lineCount: Int {
        guard case .text(let hunks) = self else { return 0 }
        return hunks.reduce(0) { $0 + $1.lines.count }
    }
}
