import Foundation

/// The folders a Claude Code tab reaches beyond its working directory, and
/// how the info pane presents them.
///
/// Paths compare as `normalized` strings, which the main actor can afford.
/// Only `comparisonKey` reads the file system, so only work off the main
/// actor (`additions`, `rows`) uses it to match `/tmp` with `/private/tmp`.
nonisolated enum AdditionalDirectories {
    static func decoded(_ data: Data) -> [String] {
        (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    /// An absolute, tilde-expanded path with `.` and `..` folded away,
    /// without consulting the file system. A relative path is taken against
    /// `base`, and is rejected without one.
    static func normalized(_ path: String, relativeTo base: String? = nil) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var expanded = (trimmed as NSString).expandingTildeInPath
        if !expanded.hasPrefix("/") {
            guard let base, base.hasPrefix("/") else { return nil }
            expanded = (base as NSString).appendingPathComponent(expanded)
        }
        let standardized = URL(fileURLWithPath: expanded, isDirectory: true).standardized.path
        return standardized.isEmpty ? nil : standardized
    }

    /// What two spellings of one folder share. The CLI reports paths exactly
    /// as passed, so `/tmp` and `/private/tmp` only match once resolved.
    static func comparisonKey(_ path: String) -> String {
        ((normalized(path) ?? path) as NSString).resolvingSymlinksInPath
    }

    /// Normalizes and dedupes `paths`, keeping first-seen order, and drops
    /// the working directory, which the session reaches already.
    static func list(_ paths: [String], excluding workingDirectory: String?) -> [String] {
        var seen = Set<String>()
        if let workingDirectory, let cwd = normalized(workingDirectory) { seen.insert(cwd) }
        return paths.compactMap { path in
            guard let normalized = normalized(path), seen.insert(normalized).inserted else { return nil }
            return normalized
        }
    }

    /// Whether a process launched with `launched` reaches a different set of
    /// folders than `stored` asks for. Order never matters to the CLI.
    static func needsRestart(launched: [String], stored: [String], launchDirectory: String?) -> Bool {
        Set(launched) != Set(list(stored, excluding: launchDirectory))
    }

    /// Splits `paths` into folders `existing` does not already reach and
    /// paths that are not folders. Reads the file system.
    static func additions(
        _ paths: [String],
        to existing: [String],
        relativeTo base: String?
    ) -> (additions: [String], rejected: [String]) {
        var seen = Set(existing.map(comparisonKey))
        var additions: [String] = []
        var rejected: [String] = []
        for path in paths {
            guard let normalized = normalized(path, relativeTo: base), isFolder(normalized) else {
                rejected.append(path)
                continue
            }
            if seen.insert(comparisonKey(normalized)).inserted { additions.append(normalized) }
        }
        return (additions, rejected)
    }

    private static func isFolder(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// The info pane's folder rows: the working directory, then the tab's
    /// own list.
    ///
    /// `workingDirectory` is where the session is now, which `EnterWorktree`
    /// can move away from `launchDirectory`, where it started. Every stored
    /// folder gets a row, even one matching either.
    ///
    /// `launched` is the list the running process started with, nil when no
    /// process is running. It differs from `added` only while a restart
    /// waits, and those differences are what the rows mark as pending. The
    /// launch never passes `launchDirectory`, so that one is never pending.
    static func rows(
        workingDirectory: String?,
        launchDirectory: String? = nil,
        added: [String],
        launched: [String]?
    ) -> [FolderRow] {
        var rows: [FolderRow] = []
        var seen = Set<String>()
        func append(_ path: String, _ pending: FolderRow.Pending) {
            guard seen.insert(comparisonKey(path)).inserted else { return }
            rows.append(FolderRow(path: path, kind: .added, pending: pending))
        }

        if let workingDirectory {
            rows.append(FolderRow(path: workingDirectory, kind: .workingDirectory, pending: .none))
        }
        var launchedKeys = launched.map { Set($0.map(comparisonKey)) }
        if let launchDirectory { launchedKeys?.insert(comparisonKey(launchDirectory)) }
        let addedKeys = Set(added.map(comparisonKey))
        for path in added {
            let isLaunched = launchedKeys?.contains(comparisonKey(path)) ?? true
            append(path, isLaunched ? .none : .addsAfterTurn)
        }
        if let workingDirectory { seen.insert(comparisonKey(workingDirectory)) }
        for path in launched ?? [] where !addedKeys.contains(comparisonKey(path)) {
            append(path, .removesAfterTurn)
        }
        return rows
    }
}

/// What the info pane's folder rows are built from, as plain values, so
/// the rows rebuild only when one of them changes.
nonisolated struct FolderRowsInput: Hashable, Sendable {
    var workingDirectory: String?
    var launchDirectory: String?
    var added: [String]
    var launched: [String]?

    func rows() -> [FolderRow] {
        AdditionalDirectories.rows(
            workingDirectory: workingDirectory,
            launchDirectory: launchDirectory,
            added: added,
            launched: launched
        )
    }
}

nonisolated struct FolderRow: Equatable, Identifiable, Sendable {
    enum Kind: Equatable {
        case workingDirectory
        case added
    }

    enum Pending: Equatable {
        case none
        case addsAfterTurn
        case removesAfterTurn
    }

    let path: String
    let kind: Kind
    let pending: Pending

    /// A stored folder can repeat the working directory's path.
    var id: String { "\(kind):\(path)" }
    var name: String { (path as NSString).lastPathComponent }
}
