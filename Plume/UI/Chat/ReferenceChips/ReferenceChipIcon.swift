import Foundation

/// The symbol a reference chip leads with, before any color scheme is known.
nonisolated struct ReferenceChipIcon: Hashable, Sendable {
    enum Tint: Hashable, Sendable {
        case neutral
        case success
        case danger
        case merged
        /// A `#rrggbb` workflow state color, as Linear reports it.
        case linear(colorHex: String)
    }

    let symbol: String
    let tint: Tint

    static func linear(_ stateType: LinearStateType, colorHex: String) -> ReferenceChipIcon {
        ReferenceChipIcon(symbol: LinearIssueGlyph.symbolName(for: stateType), tint: .linear(colorHex: colorHex))
    }

    /// The pull request chip's own state mark: merged, closed, draft or open.
    static func pullRequest(number: Int, state: PullRequestState, isDraft: Bool) -> ReferenceChipIcon {
        let pullRequest = PullRequest(number: number, state: state, isDraft: isDraft)
        let glyph = PullRequestChipContent.glyphs(for: .pullRequest(pullRequest), checkRollup: { _ in .none })
            .last { $0.symbol != nil }
        guard let glyph, let symbol = glyph.symbol else { return ReferenceChipIcon(symbol: "arrow.triangle.pull", tint: .neutral) }
        let tint: Tint = switch glyph.tint {
        case .success: .success
        case .danger: .danger
        case .merged: .merged
        case .attention, .neutral: .neutral
        }
        return ReferenceChipIcon(symbol: symbol, tint: tint)
    }

    static func file(isDirectory: Bool) -> ReferenceChipIcon {
        ReferenceChipIcon(symbol: isDirectory ? "folder" : "doc", tint: .neutral)
    }

    /// Before anything has vouched for the target.
    static func placeholder(for target: ReferenceTarget) -> ReferenceChipIcon {
        switch target {
        case .linear: ReferenceChipIcon(symbol: "circle.dashed", tint: .neutral)
        case .pullRequest: ReferenceChipIcon(symbol: "arrow.triangle.pull", tint: .neutral)
        case .file: .file(isDirectory: false)
        }
    }
}

extension ResolvedMention.State {
    nonisolated func chipIcon(number: Int?) -> ReferenceChipIcon {
        switch self {
        case let .linear(stateType, colorHex): .linear(stateType, colorHex: colorHex)
        case let .pullRequest(state, isDraft): .pullRequest(number: number ?? 0, state: state, isDraft: isDraft)
        case let .file(isDirectory): .file(isDirectory: isDirectory)
        }
    }
}
