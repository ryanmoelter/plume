import AppKit
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
    /// A neutral mark with less to say than the text beside it.
    let isDim: Bool

    init(symbol: String? = nil, text: String? = nil, tint: Tint, label: String, isDim: Bool = false) {
        self.symbol = symbol
        self.text = text
        self.tint = tint
        self.label = label
        self.isDim = isDim
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
        if let finished = finishedGlyph(pullRequest.state) { return [number, finished] }

        var glyphs = [number]
        if pullRequest.isDraft { glyphs.append(draft) }
        if let checks = checkGlyph(checkRollup(pullRequest)) { glyphs.append(checks) }
        if let review = reviewGlyph(pullRequest.reviewDecision, hasReviewers: pullRequest.hasReviewers) {
            glyphs.append(review)
        }
        // Nothing but the number to say, so the chip still reads as an open
        // pull request rather than a bare number.
        if glyphs.count == 1 { glyphs.append(open) }
        return glyphs
    }

    static let draft = PullRequestGlyph(symbol: "circle.dashed", tint: .neutral, label: "draft")
    static let open = PullRequestGlyph(symbol: "inset.filled.circle", tint: .neutral, label: "open")

    /// Nil for an open pull request.
    static func finishedGlyph(_ state: PullRequestState) -> PullRequestGlyph? {
        switch state {
        case .merged: PullRequestGlyph(symbol: "arrow.trianglehead.pull", tint: .merged, label: "merged")
        case .closed: PullRequestGlyph(symbol: "nosign", tint: .danger, label: "closed")
        case .open: nil
        }
    }

    static func checkGlyph(_ rollup: CheckRollup) -> PullRequestGlyph? {
        switch rollup {
        case .success: PullRequestGlyph(symbol: "checkmark.circle.fill", tint: .success, label: "checks pass")
        case .failure: PullRequestGlyph(symbol: "xmark.circle.fill", tint: .danger, label: "checks fail")
        case .pending: PullRequestGlyph(symbol: "circle.fill", tint: .attention, label: "checks pending")
        case .none: nil
        }
    }

    /// A pull request with a reviewer but no decision is waiting on them, and
    /// says so; one nobody was asked to review shows nothing.
    static func reviewGlyph(_ decision: ReviewDecision, hasReviewers: Bool) -> PullRequestGlyph? {
        switch decision {
        case .approved: PullRequestGlyph(symbol: "person.fill.checkmark", tint: .success, label: "approved")
        case .changesRequested: PullRequestGlyph(symbol: "person.fill.xmark", tint: .danger, label: "changes requested")
        case .none:
            hasReviewers
                ? PullRequestGlyph(symbol: "person.badge.clock", tint: .neutral, label: "awaiting review")
                : nil
        }
    }

    static func accessibilityText(for state: PullRequestFetchState) -> String? {
        accessibilityText(for: state) { $0.checkRollup() }
    }

    static func accessibilityText(
        for state: PullRequestFetchState,
        checkRollup: (PullRequest) -> CheckRollup
    ) -> String? {
        let labels = glyphs(for: state, checkRollup: checkRollup).map(\.label)
        return labels.isEmpty ? nil : labels.joined(separator: " ")
    }
}

struct PullRequestChip: View {
    let state: PullRequestFetchState
    /// The strength the verdict-free marks read at. A chip on its own row is
    /// the thing the row exists to surface; one riding on the branch line is
    /// an annotation to it, and matches that line instead.
    var emphasis: Emphasis = .primary
    /// Leads the chip with the forge's mark when known.
    var forge: ForgeKind? = nil
    /// Supplied by the store so a repository's ignored checks are honored.
    var checkRollup: (PullRequest) -> CheckRollup = { $0.checkRollup() }
    var showsNumber = true
    /// The sidebar's chip is small beside its row's title; the info pane's
    /// matches its own text.
    var font: Font = .caption
    /// The point size of `font`, for centering the number on its digits.
    var fontSize: CGFloat = NSFont.preferredFont(forTextStyle: .caption1).pointSize
    var imageScale: Image.Scale = .small
    /// Symbols carry little ink at the sidebar's size, so it asks for bold.
    var symbolWeight: Font.Weight = .regular

    var body: some View {
        let glyphs = PullRequestChipContent.glyphs(for: state, checkRollup: checkRollup)
            .filter { showsNumber || $0.text == nil }
        HStack(spacing: 4) {
            if let forge, forge.markImageName != nil, !glyphs.isEmpty {
                ForgeMarkCell(forge: forge)
                    .foregroundStyle(emphasis.textHierarchy)
                    // The mark's weight hangs below its centre, so centred on
                    // the number's cap height it still reads low.
                    .offset(y: -fontSize / 20)
            }
            HStack(spacing: 3) {
                ForEach(Array(glyphs.enumerated()), id: \.offset) { _, glyph in
                    if let text = glyph.text {
                        // The number is digits and a pound sign, with
                        // nothing below the baseline, so it centers on its
                        // cap height rather than its line box.
                        Text(text)
                            .alignmentGuide(VerticalAlignment.center) { [capHeight] in
                                $0[.firstTextBaseline] - capHeight / 2
                            }
                            .foregroundStyle(emphasis.textHierarchy)
                    } else {
                        PullRequestGlyphImage(glyph: glyph, emphasis: emphasis)
                            .fontWeight(symbolWeight)
                    }
                }
            }
        }
        .imageScale(imageScale)
        .font(font)
    }

    private var capHeight: CGFloat {
        NSFont.systemFont(ofSize: fontSize).capHeight
    }
}

/// A glyph's symbol in its tint. Verdicts take a `ChatRole` hue; the marks
/// that carry none read at `emphasis`, which is full strength wherever the
/// pull request is the thing its line exists to surface.
struct PullRequestGlyphImage: View {
    let glyph: PullRequestGlyph
    var emphasis: Emphasis = .primary

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let symbol = glyph.symbol {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .help(glyph.label)
        }
    }

    private var color: AnyShapeStyle {
        switch glyph.tint {
        case .success: AnyShapeStyle(ChatRole.success(for: colorScheme))
        case .danger: AnyShapeStyle(ChatRole.danger(for: colorScheme))
        case .attention: AnyShapeStyle(ChatRole.warning(for: colorScheme))
        case .merged: AnyShapeStyle(ChatRole.merged(for: colorScheme))
        case .neutral: AnyShapeStyle((glyph.isDim ? Emphasis.subtle : emphasis).textHierarchy)
        }
    }
}

/// The forge's own mark, in a cell the size of the worktree glyph at the
/// surrounding font and image scale, so text after it lines up with text
/// after a worktree icon. Nothing for a forge without a mark.
struct ForgeMarkCell: View {
    let forge: ForgeKind

    var body: some View {
        if let name = forge.markImageName {
            Image(systemName: "tree")
                .hidden()
                .overlay {
                    // A filled mark reads heavier than an outlined symbol of
                    // the same size, so it sits a little inside the cell.
                    Image(name)
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .scaleEffect(0.82)
                }
                .accessibilityHidden(true)
        }
    }
}

extension ForgeKind {
    var markImageName: String? {
        switch self {
        case .github: "GitHubMark"
        case .gitlab: "GitLabMark"
        case .none: nil
        }
    }
}
