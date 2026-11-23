import Foundation

/// One `@@` hunk of a unified diff.
nonisolated struct StackHunk: Equatable, Sendable {
    /// The `@@ -a,b +c,d @@ …` line.
    var header: String
    /// Every line after the header, prefix included.
    var lines: [String]
    var oldStart: Int
    var oldCount: Int
    var newStart: Int
    var newCount: Int

    /// Old-side line numbers of the lines this hunk removes.
    var removedOldLines: [Int] {
        var line = oldStart
        var removed: [Int] = []
        for text in lines {
            if text.hasPrefix("-") {
                removed.append(line)
                line += 1
            } else if text.hasPrefix(" ") {
                line += 1
            }
        }
        return removed
    }

    /// The header without the function context git appends.
    var range: String {
        guard let close = header.range(of: " @@", range: header.index(header.startIndex, offsetBy: min(2, header.count)) ..< header.endIndex)
        else { return header }
        return String(header[..<close.upperBound])
    }

    var added: Int { lines.count { $0.hasPrefix("+") } }
    var removed: Int { lines.count { $0.hasPrefix("-") } }
}

/// One file of a unified diff, as `git diff --no-renames` prints it.
nonisolated struct StackDiffFile: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case modified
        case added
        case deleted
        /// A mode change, binary contents or a path git had to quote: the
        /// hunks can't be carried on their own.
        case unsupported(String)

        static let notUTF8 = "not UTF-8 text"
    }

    var path: String
    /// From `diff --git` up to the first hunk.
    var header: [String]
    var hunks: [StackHunk]
    var kind: Kind

    /// A patch of this file holding only `hunks`, for `git apply`.
    func patch(_ hunks: [StackHunk]) -> String {
        (header + hunks.flatMap { [$0.header] + $0.lines }).joined(separator: "\n") + "\n"
    }
}

nonisolated enum StackPatch {
    /// The arguments every caller diffs with, so the output parses the same
    /// whatever the user's diff config says.
    static let diffArguments = [
        "-c", "core.quotePath=false", "diff", "--no-color", "--no-ext-diff", "--no-textconv",
        "--no-renames", "--src-prefix=a/", "--dst-prefix=b/", "--unified=1",
    ]

    static func parse(_ diff: String) -> [StackDiffFile] {
        var files: [StackDiffFile] = []
        var lines = diff.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        var index = 0
        while index < lines.count {
            guard lines[index].hasPrefix("diff --git ") else {
                index += 1
                continue
            }
            var header = [lines[index]]
            index += 1
            while index < lines.count, !lines[index].hasPrefix("@@"), !lines[index].hasPrefix("diff --git ") {
                header.append(lines[index])
                index += 1
            }
            var hunks: [StackHunk] = []
            while index < lines.count, lines[index].hasPrefix("@@") {
                let hunkHeader = lines[index]
                index += 1
                var body: [String] = []
                while index < lines.count, !lines[index].hasPrefix("@@"), !lines[index].hasPrefix("diff --git ") {
                    body.append(lines[index])
                    index += 1
                }
                if let hunk = hunk(hunkHeader, body) { hunks.append(hunk) }
            }
            files.append(file(header, hunks))
        }
        return files
    }

    private static func file(_ header: [String], _ hunks: [StackHunk]) -> StackDiffFile {
        func side(_ prefix: String) -> String? {
            guard var path = header.first(where: { $0.hasPrefix(prefix) }).map({ String($0.dropFirst(prefix.count)) }) else { return nil }
            if path.hasSuffix("\t") { path.removeLast() }
            return path
        }
        let old = side("--- ")
        let new = side("+++ ")
        var path: String
        if let named = [new, old].compactMap({ $0 }).first(where: { $0 != "/dev/null" }) {
            path = named.hasPrefix("a/") || named.hasPrefix("b/") ? String(named.dropFirst(2)) : named
        } else {
            // `diff --git a/<path> b/<path>`, the same path twice without renames.
            let both = header[0].dropFirst("diff --git a/".count)
            path = String(both.prefix(max(0, (both.count - 3) / 2)))
        }
        let kind: StackDiffFile.Kind
        if path.hasPrefix("\"") {
            kind = .unsupported("path needs quoting")
        } else if hunks.contains(where: { $0.lines.contains { $0.contains("\u{FFFD}") } }) {
            // Output is decoded as UTF-8, so other bytes arrive replaced and
            // a patch of them would commit the replacement character.
            kind = .unsupported(StackDiffFile.Kind.notUTF8)
        } else if header.contains(where: { $0.hasPrefix("old mode") || $0.hasPrefix("new mode") }) {
            kind = .unsupported("mode change")
        } else if hunks.isEmpty {
            kind = .unsupported("binary or empty")
        } else if old == "/dev/null" {
            kind = .added
        } else if new == "/dev/null" {
            kind = .deleted
        } else {
            kind = .modified
        }
        return StackDiffFile(path: path, header: header, hunks: hunks, kind: kind)
    }

    /// `@@ -a[,b] +c[,d] @@`; an omitted count is 1.
    private static func hunk(_ header: String, _ lines: [String]) -> StackHunk? {
        let fields = header.split(separator: " ")
        guard fields.count >= 3, fields[1].hasPrefix("-"), fields[2].hasPrefix("+") else { return nil }
        func range(_ field: Substring) -> (Int, Int)? {
            let parts = field.dropFirst().split(separator: ",", omittingEmptySubsequences: false)
            guard let start = Int(parts[0]) else { return nil }
            guard parts.count > 1 else { return (start, 1) }
            return Int(parts[1]).map { (start, $0) }
        }
        guard let old = range(fields[1]), let new = range(fields[2]) else { return nil }
        return StackHunk(header: header, lines: lines, oldStart: old.0, oldCount: old.1, newStart: new.0, newCount: new.1)
    }
}

nonisolated extension Stack {
    /// For the commands that write commits from the index or the working
    /// tree, where any half-done operation's state would be swept in.
    static func requireNoOperationInProgress(_ ctx: StackContext) throws {
        if try rebaseInProgress(ctx) {
            throw CLIFailure("a rebase is in progress — `git rebase --continue` or `git rebase --abort` first")
        }
        for (ref, name) in [("MERGE_HEAD", "merge"), ("CHERRY_PICK_HEAD", "cherry-pick"), ("REVERT_HEAD", "revert")]
        where ctx.git.resolve(ref) != nil {
            throw CLIFailure("a \(name) is in progress — finish or abort it first")
        }
    }
}

/// Trees built without touching the index or the working tree, through a
/// scratch index file.
nonisolated extension StackContext {
    /// `tree` with `patch` applied, or nil when it doesn't apply.
    func applying(_ patch: String, to tree: String) throws -> String? {
        let index = NSTemporaryDirectory() + "plume-stack-\(UUID().uuidString).index"
        defer { try? FileManager.default.removeItem(atPath: index) }
        let environment = ["GIT_INDEX_FILE=\(index)"]
        _ = try gitWithEnvironment(environment, ["read-tree", tree])
        // Paths in the patch are relative to the top level, and apply skips
        // any outside the directory it runs in.
        let top = try git.git("rev-parse", "--show-toplevel")
        let applied = try CLIProcess.run(
            environment + ["git", "-C", top, "apply", "--cached", "--whitespace=nowarn", "-"],
            check: false,
            input: patch,
            workingDirectory: git.workingDirectory
        )
        guard applied.status == 0 else { return nil }
        return try gitWithEnvironment(environment, ["write-tree"])
    }

    /// A commit of `tree` on `parent` carrying `original`'s author and
    /// message, as a rebase would write it.
    func recommit(_ original: String, tree: String, parent: String) throws -> String {
        let fields = try git.git("log", "-1", "--format=%an%x00%ae%x00%ad", "--date=raw", original).components(separatedBy: "\u{0}")
        guard fields.count == 3 else { throw CLIFailure("could not read the author of \(original.prefix(12))") }
        let message = try git.run(["log", "-1", "--format=%B", original]).stdout
        if message.contains("\u{FFFD}") || fields[0].contains("\u{FFFD}") {
            throw CLIFailure("\(original.prefix(12))'s message or author isn't UTF-8 — it can't be rewritten without changing it")
        }
        let environment = ["GIT_AUTHOR_NAME=\(fields[0])", "GIT_AUTHOR_EMAIL=\(fields[1])", "GIT_AUTHOR_DATE=\(fields[2])"]
        let result = try CLIProcess.run(
            environment + ["git", "commit-tree", tree, "-p", parent, "-F", "-"],
            check: false,
            input: message,
            workingDirectory: git.workingDirectory
        )
        guard result.status == 0 else {
            throw CLIFailure("`git commit-tree` failed: \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `commit` replayed onto `onto` with `merge-tree`: the new tree, or nil
    /// on a conflict.
    func replayTree(_ commit: String, onto: String) throws -> String? {
        let merge = try git.run(["merge-tree", "--write-tree", "--merge-base=\(commit)^", onto, commit])
        if merge.status == 1 { return nil }
        guard merge.status == 0 else {
            throw CLIFailure("`git merge-tree` failed: \(merge.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return merge.stdout.split(whereSeparator: \.isWhitespace).first.map(String.init)
    }

    private func gitWithEnvironment(_ environment: [String], _ arguments: [String]) throws -> String {
        let result = try CLIProcess.run(environment + ["git"] + arguments, check: false, workingDirectory: git.workingDirectory)
        guard result.status == 0 else {
            throw CLIFailure("`git \(arguments.joined(separator: " "))` failed: \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
