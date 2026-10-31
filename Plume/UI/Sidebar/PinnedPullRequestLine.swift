import SwiftUI

/// A pull request pinned to the task, as one line under its name in the sidebar.
struct PinnedPullRequestLine: View {
    let reference: PullRequestReference
    let detail: LinkedPullRequestStore.Detail?

    @Environment(\.colorScheme) private var colorScheme

    private var pull: MentionCandidate.PullRequestEntry? {
        if case .pullRequest(let pull) = detail { pull } else { nil }
    }

    var body: some View {
        HStack(spacing: 4) {
            if let pull {
                Image(systemName: MentionAutocompleteView.symbol(for: pull))
                    .font(.caption)
                    .imageScale(.small)
                    .foregroundStyle(MentionAutocompleteView.tint(for: pull, colorScheme: colorScheme))
            } else {
                PinnedPullRequestOverflowLine.symbol
            }
            if let title = pull?.title {
                Text(title)
                    .font(.caption)
                    .emphasis(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Text("#\(reference.number)")
                .font(.caption)
                .emphasis(.secondary)
                .lineLimit(1)
                .fixedSize()
        }
        .help(reference.url)
        .plumeID(AccessibilityID.taskPinnedPullRequestLine, label: "#\(reference.number)", value: reference.url)
    }
}

struct PinnedPullRequestOverflowLine: View {
    let count: Int

    static var symbol: some View {
        Image(systemName: "arrow.triangle.pull")
            .font(.caption)
            .imageScale(.small)
            .emphasis(.secondary)
    }

    var body: some View {
        HStack(spacing: 4) {
            Self.symbol
            Text("+\(count) more")
                .font(.caption)
                .emphasis(.secondary)
        }
    }
}
