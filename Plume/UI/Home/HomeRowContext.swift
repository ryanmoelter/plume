import Foundation

/// The dim line under a Home row: the project, the branch, and the Linear
/// issues and pull requests the task is working on.
struct HomeRowContext: Equatable {
    struct Reference: Equatable {
        let id: String
        /// Nil until the reference's state is known; the id shows regardless.
        var icon: ReferenceChipIcon?
    }

    enum Segment: Equatable {
        case project(String)
        case branch(String, isWorktree: Bool, isLocalOnly: Bool)
        /// The first reference, and how many more there are.
        case issue(Reference, more: Int)
        case pullRequest(Reference, more: Int)
    }

    var project: String?
    var branch: String?
    var isWorktree = false
    /// The branch has never been pushed.
    var isLocalOnly = false
    var issues: [Reference] = []
    var pullRequests: [Reference] = []

    /// Empty when there is nothing to say, so the row drops the line.
    var segments: [Segment] {
        var segments: [Segment] = []
        if let project, !project.isEmpty { segments.append(.project(project)) }
        if let branch, !branch.isEmpty {
            segments.append(.branch(branch, isWorktree: isWorktree, isLocalOnly: isLocalOnly))
        }
        if let first = issues.first { segments.append(.issue(first, more: issues.count - 1)) }
        if let first = pullRequests.first { segments.append(.pullRequest(first, more: pullRequests.count - 1)) }
        return segments
    }
}
