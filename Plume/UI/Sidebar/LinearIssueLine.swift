import SwiftUI

/// A working Linear issue under a task's name: logo, state glyph, title,
/// identifier. The title gives way first, so the identifier always shows.
struct LinearIssueLine: View {
    let identifier: String
    let state: LinearIssueFetchState?

    var body: some View {
        HStack(spacing: 4) {
            LinearLogo(size: 10)
                .emphasis(.secondary)
            if let issue = state?.issue {
                LinearIssueGlyph(stateType: issue.stateType, colorHex: issue.stateColor)
                    .font(.caption)
                    .imageScale(.small)
                Text(issue.title)
                    .font(.caption)
                    .emphasis(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Text(identifier)
                .font(.caption)
                .emphasis(.secondary)
                .lineLimit(1)
                .fixedSize()
            if state?.issue == nil, let word = TaskRowDetails.linearStatusWord(state) {
                Text(word)
                    .font(.caption)
                    .emphasis(.subtle)
                    .lineLimit(1)
            }
            if case .stale(_, let reason) = state {
                Image(systemName: "exclamationmark.circle")
                    .font(.caption)
                    .imageScale(.small)
                    .emphasis(.secondary)
                    .help(reason)
            }
        }
        .help(state?.issue.map { "\($0.stateName): \($0.title)" } ?? "")
        .plumeID(AccessibilityID.taskLinearIssueLine, label: identifier)
    }
}
