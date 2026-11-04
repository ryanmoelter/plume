import SwiftUI

/// A pull request pinned to the task, as one line under its name in the sidebar.
struct PinnedPullRequestLine: View {
    let reference: PullRequestReference
    let detail: LinkedPullRequestStore.Detail?

    var body: some View {
        Group {
            if case .pullRequest(let pull) = detail {
                PullRequestLine(summary: PullRequestSummary(pull))
            } else {
                HStack(spacing: 4) {
                    PinnedPullRequestOverflowLine.symbol
                    Text("#\(reference.number)")
                        .font(.caption)
                        .emphasis(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
        }
        .help(reference.url)
        .plumeID(AccessibilityID.taskPinnedPullRequestLine, label: "#\(reference.number)", value: reference.url)
    }
}

/// A pull request as one sidebar line: its status, title and number, then
/// the checks and review glyphs the status did not take. The branch's own
/// pull request and pinned ones draw the same way.
struct PullRequestLine: View {
    let summary: PullRequestSummary

    var body: some View {
        HStack(spacing: 4) {
            glyph(PullRequestRowContent.leading(summary))
            if let title = summary.title {
                Text(title)
                    .emphasis(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Text("#\(summary.number)")
                .emphasis(.secondary)
                .lineLimit(1)
                .fixedSize()
            ForEach(Array(PullRequestRowContent.trailing(summary).enumerated()), id: \.offset) {
                glyph($0.element)
            }
        }
        .font(.caption)
        .imageScale(.small)
    }

    /// Symbols carry little ink at the sidebar's size, so they draw bold.
    private func glyph(_ glyph: PullRequestGlyph) -> some View {
        PullRequestGlyphImage(glyph: glyph, emphasis: .secondary)
            .fontWeight(.bold)
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
