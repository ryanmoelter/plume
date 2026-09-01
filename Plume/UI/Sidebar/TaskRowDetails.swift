import Foundation

/// The dim lines under a task's name in the sidebar.
///
/// Pure so the ordering and the omissions are testable without a view — and so
/// collapsing the row to a single joined line later is a different join of the
/// same array.
enum TaskRowDetails {
    static func lines(
        status: TaskStatus,
        branch: String?,
        workingDirectory: String?
    ) -> [String] {
        var lines: [String] = []
        if let status = statusText(status) { lines.append(status) }
        if let branch, !branch.isEmpty { lines.append(branch) }
        if let directory = directoryName(workingDirectory) { lines.append(directory) }
        return lines
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
}
