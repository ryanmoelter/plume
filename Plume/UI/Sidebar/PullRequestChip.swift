import SwiftUI

/// One mark in a pull request chip, before any color scheme is known.
///
/// Pure so the composition order and the suppression rules are testable
/// without a view — `TaskRowDetails` is the same arrangement.
nonisolated struct PullRequestGlyph: Equatable {
    enum Tint: Equatable {
        case success
        case danger
        case attention
        case merged
        /// Carries no verdict of its own.
        case neutral
    }

    /// An SF Symbol name, or nil when the mark is literal text.
    let symbol: String?
    let text: String?
    let tint: Tint
    /// What the mark contributes to the row's accessibility label.
    let label: String

    init(symbol: String? = nil, text: String? = nil, tint: Tint, label: String) {
        self.symbol = symbol
        self.text = text
        self.tint = tint
        self.label = label
    }
}

nonisolated enum PullRequestChipContent {
    /// The glyphs a state draws, left to right: number, draft, checks, review.
    ///
    /// Merged and closed show only their own glyph — checks and review on a
    /// finished pull request are history, and a draft marker on one is noise.
    static func glyphs(
        for state: PullRequestFetchState,
        checkRollup: (PullRequest) -> CheckRollup = { $0.checkRollup() }
    ) -> [PullRequestGlyph] {
        switch state {
        case .forgeUnsupported:
            return []
        case .loading:
            return [PullRequestGlyph(symbol: "ellipsis", tint: .neutral, label: "loading")]
        case .timedOut:
            return [PullRequestGlyph(symbol: "clock", tint: .neutral, label: "timed out")]
        case .failed:
            return [PullRequestGlyph(symbol: "wifi.exclamationmark", tint: .danger, label: "PR status unavailable")]
        case .localOnly:
            return [PullRequestGlyph(symbol: "network.slash", tint: .neutral, label: "local only")]
        case .noPR:
            return [PullRequestGlyph(symbol: "minus", tint: .neutral, label: "no PR")]
        case .pullRequest(let pullRequest):
            return glyphs(for: pullRequest, checkRollup: checkRollup)
        }
    }

    private static func glyphs(
        for pullRequest: PullRequest,
        checkRollup: (PullRequest) -> CheckRollup
    ) -> [PullRequestGlyph] {
        let number = PullRequestGlyph(
            text: "#\(pullRequest.number)",
            tint: .neutral,
            label: "PR #\(pullRequest.number)"
        )
        switch pullRequest.state {
        case .merged:
            return [number, PullRequestGlyph(symbol: "arrow.triangle.merge", tint: .merged, label: "merged")]
        case .closed:
            return [number, PullRequestGlyph(symbol: "nosign", tint: .danger, label: "closed")]
        case .open:
            break
        }

        var glyphs = [number]
        if pullRequest.isDraft {
            glyphs.append(PullRequestGlyph(symbol: "circle.dashed", tint: .neutral, label: "draft"))
        }
        switch checkRollup(pullRequest) {
        case .success:
            glyphs.append(PullRequestGlyph(symbol: "checkmark.circle.fill", tint: .success, label: "checks pass"))
        case .failure:
            glyphs.append(PullRequestGlyph(symbol: "xmark.circle.fill", tint: .danger, label: "checks fail"))
        case .pending:
            glyphs.append(PullRequestGlyph(symbol: "circle.fill", tint: .attention, label: "checks pending"))
        case .none:
            break
        }
        switch pullRequest.reviewDecision {
        case .approved:
            glyphs.append(PullRequestGlyph(symbol: "person.fill.checkmark", tint: .success, label: "approved"))
        case .changesRequested:
            glyphs.append(PullRequestGlyph(symbol: "person.fill.xmark", tint: .danger, label: "changes requested"))
        case .none:
            break
        }
        // Nothing but the number to say, so the chip still reads as an open
        // pull request rather than a bare number.
        if glyphs.count == 1 {
            glyphs.append(PullRequestGlyph(symbol: "inset.filled.circle", tint: .neutral, label: "open"))
        }
        return glyphs
    }

    static func accessibilityText(for state: PullRequestFetchState) -> String? {
        let labels = glyphs(for: state).map(\.label)
        return labels.isEmpty ? nil : labels.joined(separator: " ")
    }
}

struct PullRequestChip: View {
    let state: PullRequestFetchState
    /// The strength the verdict-free marks read at. A chip on its own row is
    /// the thing the row exists to surface; one riding on the branch line is
    /// an annotation to it, and matches that line instead.
    var emphasis: Emphasis = .primary
    /// Supplied by the store so a repository's ignored checks are honored.
    var checkRollup: (PullRequest) -> CheckRollup = { $0.checkRollup() }

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let glyphs = PullRequestChipContent.glyphs(for: state, checkRollup: checkRollup)
        HStack(spacing: 3) {
            ForEach(Array(glyphs.enumerated()), id: \.offset) { _, glyph in
                Group {
                    if let symbol = glyph.symbol {
                        Image(systemName: symbol).imageScale(.small)
                    } else if let text = glyph.text {
                        Text(text)
                    }
                }
                .foregroundStyle(color(for: glyph.tint))
            }
        }
        .font(.caption)
    }

    /// Verdicts take a `ChatRole` hue. The marks that carry none still read at
    /// full strength: the pull request is the line the row exists to surface,
    /// so it sits above the directory and branch that locate it.
    private func color(for tint: PullRequestGlyph.Tint) -> AnyShapeStyle {
        switch tint {
        case .success: AnyShapeStyle(ChatRole.success(for: colorScheme))
        case .danger: AnyShapeStyle(ChatRole.danger(for: colorScheme))
        case .attention: AnyShapeStyle(ChatRole.warning(for: colorScheme))
        case .merged: AnyShapeStyle(ChatRole.merged(for: colorScheme))
        case .neutral: AnyShapeStyle(emphasis.textHierarchy)
        }
    }
}
