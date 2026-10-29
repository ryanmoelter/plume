import Foundation

/// One row the mention menu can offer.
nonisolated enum MentionCandidate: Identifiable, Hashable, Sendable {
    case file(FileEntry)
    case linear(LinearIssue)
    case pullRequest(PullRequestEntry)
    /// The header of a source's section, which types that source's filter
    /// prefix, `@linear:`.
    case filter(MentionQuery.Filter)

    enum Source: Hashable, Sendable {
        case files
        case linear
        case pullRequests
    }

    struct FileEntry: Hashable, Sendable {
        /// Relative to the tab directory, or absolute (`/…` or `~/…`) for a
        /// query typed as an absolute path.
        let path: String
        let isDirectory: Bool

        var name: String { (path as NSString).lastPathComponent }

        /// The containing folder, empty for an entry at the root.
        var folder: String {
            let parent = (path as NSString).deletingLastPathComponent
            return parent == "." ? "" : parent
        }
    }

    struct LinearIssue: Hashable, Sendable {
        let identifier: String
        let title: String
        let url: String
        let stateType: LinearStateType
        /// A `#rrggbb` hex string, as Linear reports it.
        let stateColor: String
        let updatedAt: Date

        /// The identifier's prefix, `DROID` in `DROID-123`.
        var teamKey: String {
            identifier.split(separator: "-", maxSplits: 1).first.map(String.init) ?? identifier
        }

        var isOpen: Bool {
            switch stateType {
            case .completed, .canceled, .duplicate: false
            default: true
            }
        }
    }

    struct PullRequestEntry: Hashable, Sendable {
        let number: Int
        let title: String
        let url: String
        let state: PullRequestState
        let isDraft: Bool
        let updatedAt: Date?
    }

    var id: String {
        switch self {
        case .file(let entry): "file:\(entry.path)"
        case .linear(let issue): "linear:\(issue.identifier)"
        case .pullRequest(let pull): "pr:\(pull.url)"
        case .filter(let filter): "filter:\(filter.rawValue)"
        }
    }

    /// Nil for a filter row, which no source supplies.
    var source: Source? {
        switch self {
        case .file: .files
        case .linear: .linear
        case .pullRequest: .pullRequests
        case .filter: nil
        }
    }

    var isSectionHeader: Bool {
        if case .filter = self { true } else { false }
    }

    /// Accepting it types a prefix and keeps the menu open on what follows:
    /// a folder lists what is inside it, a filter row its one source.
    var drillsIn: Bool {
        switch self {
        case .file(let entry): entry.isDirectory
        case .filter: true
        case .linear, .pullRequest: false
        }
    }
}
