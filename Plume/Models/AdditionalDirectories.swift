import Foundation

/// The folders a Claude Code tab reaches beyond its working directory, and
/// how the info pane presents them.
enum AdditionalDirectories {
    /// An absolute, tilde-expanded, standardized path. A relative path is
    /// taken against `base`, and is rejected without one.
    static func normalized(_ path: String, relativeTo base: String? = nil) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var expanded = (trimmed as NSString).expandingTildeInPath
        if !expanded.hasPrefix("/") {
            guard let base, base.hasPrefix("/") else { return nil }
            expanded = (base as NSString).appendingPathComponent(expanded)
        }
        let standardized = (expanded as NSString).standardizingPath
        return standardized.isEmpty ? nil : standardized
    }

    /// What two spellings of one folder share. The CLI reports paths exactly
    /// as passed, so `/tmp` and `/private/tmp` only match once resolved.
    static func comparisonKey(_ path: String) -> String {
        let standardized = (path as NSString).standardizingPath
        return (standardized as NSString).resolvingSymlinksInPath
    }

    /// Normalizes and dedupes `paths`, keeping first-seen order, and drops
    /// the working directory, which the session reaches already.
    static func list(_ paths: [String], excluding workingDirectory: String?) -> [String] {
        var seen = Set<String>()
        if let workingDirectory, let cwd = normalized(workingDirectory) {
            seen.insert(comparisonKey(cwd))
        }
        var result: [String] = []
        for path in paths {
            guard let normalized = normalized(path), seen.insert(comparisonKey(normalized)).inserted else { continue }
            result.append(normalized)
        }
        return result
    }

    /// The info pane's folder rows: the working directory, then Plume's own
    /// list, then whatever else the session reports reaching.
    ///
    /// `launched` is the list the running process started with, nil when no
    /// process is running. It differs from `added` only while a restart
    /// waits for the turn to end, and those differences are what the rows
    /// mark as pending.
    static func rows(
        workingDirectory: String?,
        added: [String],
        launched: [String]?,
        reported: [String]
    ) -> [FolderRow] {
        var rows: [FolderRow] = []
        var seen = Set<String>()
        func append(_ path: String, _ kind: FolderRow.Kind, _ pending: FolderRow.Pending = .none) {
            guard seen.insert(comparisonKey(path)).inserted else { return }
            rows.append(FolderRow(path: path, kind: kind, pending: pending))
        }

        if let workingDirectory { append(workingDirectory, .workingDirectory) }
        let launchedKeys = launched.map { Set($0.map(comparisonKey)) }
        let addedKeys = Set(added.map(comparisonKey))
        for path in added {
            let isLaunched = launchedKeys?.contains(comparisonKey(path)) ?? true
            append(path, .added, isLaunched ? .none : .addsAfterTurn)
        }
        for path in launched ?? [] where !addedKeys.contains(comparisonKey(path)) {
            append(path, .added, .removesAfterTurn)
        }
        for path in reported { append(path, .foreign) }
        return rows
    }
}

struct FolderRow: Equatable, Identifiable {
    enum Kind: Equatable {
        case workingDirectory
        /// In the tab's own list, so Plume can remove it.
        case added
        /// Reported by the session but not passed by Plume — a grant made
        /// inside the session, or the user's own settings.
        case foreign
    }

    enum Pending: Equatable {
        case none
        case addsAfterTurn
        case removesAfterTurn
    }

    let path: String
    let kind: Kind
    let pending: Pending

    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
}
