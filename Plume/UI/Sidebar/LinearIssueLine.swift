import SwiftUI

/// A working Linear issue under a task's name: state glyph, identifier, state name.
struct LinearIssueLine: View {
    let identifier: String
    let state: LinearIssueFetchState?

    var body: some View {
        HStack(spacing: 4) {
            if let issue = state?.issue {
                LinearIssueGlyph(stateType: issue.stateType, colorHex: issue.stateColor)
                    .font(.caption)
                    .imageScale(.small)
            }
            Text(text)
                .font(.caption)
                .emphasis(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if case .stale(_, let reason) = state {
                Image(systemName: "exclamationmark.circle")
                    .font(.caption)
                    .imageScale(.small)
                    .emphasis(.secondary)
                    .help(reason)
            }
        }
        .help(state?.issue?.title ?? "")
        .plumeID(AccessibilityID.taskLinearIssueLine, label: identifier)
    }

    private var text: String {
        if let issue = state?.issue { return "\(identifier) · \(issue.stateName)" }
        if let word = TaskRowDetails.linearStatusWord(state) { return "\(identifier) · \(word)" }
        return identifier
    }
}
