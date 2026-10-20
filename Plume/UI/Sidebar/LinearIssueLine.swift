import SwiftUI

/// A working Linear issue under a task's name: logo, identifier, state glyph, state name.
struct LinearIssueLine: View {
    let identifier: String
    let state: LinearIssueFetchState?

    var body: some View {
        HStack(spacing: 4) {
            LinearLogo(size: 10)
                .emphasis(.secondary)
            Text(suffix == nil ? identifier : "\(identifier) ·")
                .font(.caption)
                .emphasis(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if let issue = state?.issue {
                LinearIssueGlyph(stateType: issue.stateType, colorHex: issue.stateColor)
                    .font(.caption)
                    .imageScale(.small)
            }
            if let suffix {
                Text(suffix)
                    .font(.caption)
                    .emphasis(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
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

    private var suffix: String? {
        state?.issue?.stateName ?? TaskRowDetails.linearStatusWord(state)
    }
}
