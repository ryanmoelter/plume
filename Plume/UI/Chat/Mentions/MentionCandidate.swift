import Foundation

/// One row the mention menu can offer.
nonisolated enum MentionCandidate: Identifiable, Hashable, Sendable {
    case file(FileEntry)
    case linear(LinearIssue)
    case pullRequest(PullRequestEntry)

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
        }
    }

    var source: Source {
        switch self {
        case .file: .files
        case .linear: .linear
        case .pullRequest: .pullRequests
        }
    }
}
