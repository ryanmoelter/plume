import Foundation

/// A line-level diff of an `Edit` or a `Write`, ready to render.
nonisolated struct FileDiff: Equatable {
    enum LineKind: Equatable {
        case context
        case removed
        case added
    }

    struct Line: Equatable {
        let kind: LineKind
        let text: String
    }

    /// The file the change applies to, for the header.
    let path: String?
    let lines: [Line]
    /// Set when the rendered lines are a prefix of a longer change.
    let truncatedLineCount: Int

    var addedCount: Int { lines.count { $0.kind == .added } }
    var removedCount: Int { lines.count { $0.kind == .removed } }
}

/// Turns an `Edit`'s `old_string`/`new_string` or a `Write`'s `content` into a
/// `FileDiff`.
///
/// The diff is a common-prefix/common-suffix trim rather than a real LCS: an
/// `Edit` replaces one contiguous region, so trimming the matching ends is
/// already the whole answer for the shape these tools produce, and it costs a
/// single pass instead of a quadratic table.
nonisolated enum FileDiffBuilder {
    /// Beyond this the diff renders as a prefix with a count. A generated file
    /// written in one `Write` runs to thousands of lines, and none of them are
    /// worth laying out inside a collapsed row.
    static let maxRenderedLines = 400

    static func diff(name: String, input: [String: JSONValue]) -> FileDiff? {
        let path = input["file_path"]?.stringValue
        switch name {
        case "Write":
            guard let content = input["content"]?.stringValue else { return nil }
            return build(path: path, oldText: "", newText: content)
        case "Edit":
            guard let oldText = input["old_string"]?.stringValue,
                  let newText = input["new_string"]?.stringValue
            else { return nil }
            return build(path: path, oldText: oldText, newText: newText)
        default:
            return nil
        }
    }

    static func build(path: String?, oldText: String, newText: String) -> FileDiff {
        let oldLines = split(oldText)
        let newLines = split(newText)

        var prefix = 0
        while prefix < oldLines.count, prefix < newLines.count, oldLines[prefix] == newLines[prefix] {
            prefix += 1
        }
        var suffix = 0
        while suffix < oldLines.count - prefix,
              suffix < newLines.count - prefix,
              oldLines[oldLines.count - 1 - suffix] == newLines[newLines.count - 1 - suffix] {
            suffix += 1
        }

        var lines: [FileDiff.Line] = []
        lines += oldLines[..<prefix].map { FileDiff.Line(kind: .context, text: $0) }
        lines += oldLines[prefix..<(oldLines.count - suffix)].map { FileDiff.Line(kind: .removed, text: $0) }
        lines += newLines[prefix..<(newLines.count - suffix)].map { FileDiff.Line(kind: .added, text: $0) }
        lines += oldLines[(oldLines.count - suffix)...].map { FileDiff.Line(kind: .context, text: $0) }

        let truncated = max(0, lines.count - maxRenderedLines)
        return FileDiff(
            path: path,
            lines: truncated > 0 ? Array(lines.prefix(maxRenderedLines)) : lines,
            truncatedLineCount: truncated
        )
    }

    /// An empty string is no lines at all, not one blank line — a `Write`
    /// against it must read as pure addition.
    private static func split(_ text: String) -> [String] {
        text.isEmpty ? [] : text.components(separatedBy: "\n")
    }
}
