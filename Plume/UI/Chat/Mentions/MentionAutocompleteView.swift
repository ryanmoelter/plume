import SwiftUI

/// The mention menu above the composer: files, Linear issues and pull
/// requests, already matched and ranked by `MentionAutocompleteController`.
struct MentionAutocompleteView: View, ThemedView {
    @Environment(\.theme) var theme
    @Environment(\.colorScheme) private var colorScheme

    let candidates: [MentionCandidate]
    let selectedIndex: Int
    let isLoading: Bool
    let onSelect: (Int) -> Void
    var isTopOfPanel = true

    var body: some View {
        ComposerSuggestionPanel(
            items: candidates,
            selectedIndex: selectedIndex,
            onSelect: onSelect,
            isTopOfPanel: isTopOfPanel,
            footer: isLoading ? "Searching…" : nil,
            row: row
        )
        .plumeID(AccessibilityID.composerMentionMenu)
    }

    private func row(_ candidate: MentionCandidate) -> some View {
        let index = candidates.firstIndex(of: candidate)
        return HStack(spacing: 8) {
            switch candidate {
            case .linear(let issue):
                LinearIssueGlyph(stateType: issue.stateType, colorHex: issue.stateColor)
                    .imageScale(.small)
                Text(issue.identifier)
                    .font(typography.caption.monoMedium)
                title(issue.title)
            case .pullRequest(let pull):
                Image(systemName: Self.symbol(for: pull))
                    .imageScale(.small)
                    .foregroundStyle(tint(for: pull))
                Text("#\(pull.number)")
                    .font(typography.caption.monoMedium)
                title(pull.title)
            case .file(let entry):
                Image(systemName: entry.isDirectory ? "folder" : "doc")
                    .imageScale(.small)
                    .emphasis(.secondary)
                Text(entry.isDirectory ? entry.name + "/" : entry.name)
                    .font(typography.caption.monoMedium)
                    .lineLimit(1)
                if !entry.folder.isEmpty {
                    Text(entry.folder)
                        .font(typography.caption.font)
                        .emphasis(.subtle)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            Spacer(minLength: 0)
        }
        .plumeID(
            AccessibilityID.composerMentionRow,
            label: Self.label(for: candidate),
            value: index == selectedIndex ? "selected" : nil,
            invoke: index.map { index in { onSelect(index) } }
        )
    }

    private func title(_ text: String) -> some View {
        Text(text)
            .font(typography.caption.font)
            .emphasis(.secondary)
            .lineLimit(1)
    }

    static func label(for candidate: MentionCandidate) -> String {
        switch candidate {
        case .linear(let issue): issue.identifier
        case .pullRequest(let pull): "#\(pull.number)"
        case .file(let entry): entry.path
        }
    }

    private static func symbol(for pull: MentionCandidate.PullRequestEntry) -> String {
        switch pull.state {
        case .merged: "arrow.trianglehead.pull"
        case .closed: "nosign"
        case .open: pull.isDraft ? "circle.dashed" : "arrow.trianglehead.pull"
        }
    }

    private func tint(for pull: MentionCandidate.PullRequestEntry) -> AnyShapeStyle {
        switch pull.state {
        case .merged: AnyShapeStyle(ChatRole.merged(for: colorScheme))
        case .closed: AnyShapeStyle(ChatRole.danger(for: colorScheme))
        case .open: pull.isDraft ? AnyShapeStyle(.secondary) : AnyShapeStyle(ChatRole.success(for: colorScheme))
        }
    }
}
