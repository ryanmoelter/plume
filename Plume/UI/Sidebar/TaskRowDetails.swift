import Foundation

/// The dim lines under a task's name in the sidebar.
///
/// Pure so the ordering and the omissions are testable without a view — and so
/// collapsing the row to a single joined line later is a different join of the
/// same array.
enum TaskRowDetails {
    /// One line, either words or the pull request chip's own drawing.
    enum Line: Equatable {
        case text(String)
        case pullRequest(PullRequestFetchState)
    }

    static func lines(
        status: TaskStatus,
        branch: String?,
        workingDirectory: String?,
        pullRequest: PullRequestFetchState? = nil
    ) -> [Line] {
        var lines: [Line] = []
        if let status = statusText(status) { lines.append(.text(status)) }
        if let branch, !branch.isEmpty { lines.append(.text(branch)) }
        if let pullRequest, let line = pullRequestLine(pullRequest) { lines.append(line) }
        if let directory = directoryName(workingDirectory) { lines.append(.text(directory)) }
        return lines
    }

    /// A state with nothing to draw takes no line — a non-GitHub origin must
    /// not push the row taller for an empty chip.
    static func pullRequestLine(_ state: PullRequestFetchState) -> Line? {
        PullRequestChipContent.glyphs(for: state).isEmpty ? nil : .pullRequest(state)
    }

    /// `.unset` means no agent has ever run, which is not worth a line.
    static func statusText(_ status: TaskStatus) -> String? {
        switch status {
        case .unset: nil
        case .needsInput: "needs input"
        default: status.rawValue
        }
    }

    static func directoryName(_ path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? nil : name
    }

    static func accessibilityText(_ line: Line) -> String? {
        switch line {
        case .text(let text): text
        case .pullRequest(let state): PullRequestChipContent.accessibilityText(for: state)
        }
    }
}
