import AppKit
import SwiftUI

/// What the Linear section does to the task. Each closure acts on the tab's
/// task, so the section never sees it.
struct InfoPaneLinearActions {
    let promote: (String) -> Void
    let unlink: (String) -> Void
    /// False when the text is not a Linear issue identifier or URL.
    let link: (String) -> Bool

    static let none = InfoPaneLinearActions(promote: { _ in }, unlink: { _ in }, link: { _ in false })
}

struct LinearIssuesSection: View, ThemedView {
    @Environment(\.theme) var theme

    let linear: InfoPaneFacts.LinearFacts?
    let actions: InfoPaneLinearActions

    var body: some View {
        if let linear {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: InfoPaneLayout.columnSpacing) {
                    InfoPaneIcon { Image(systemName: "circle.lefthalf.filled") }
                    Text("Linear")
                    Spacer(minLength: 0)
                }
                .emphasis(.secondary)
                .padding(.vertical, InfoPaneLayout.rowVerticalPadding)

                ForEach(linear.working) { IssueRow(issue: $0, actions: actions) }
                if !linear.mentioned.isEmpty {
                    Text("Mentioned")
                        .emphasis(.subtle)
                        .padding(.top, InfoPaneLayout.rowVerticalPadding)
                    ForEach(linear.mentioned) { IssueRow(issue: $0, actions: actions) }
                }
                LinkIssueField(actions: actions)
                    .padding(.vertical, InfoPaneLayout.rowVerticalPadding)
            }
        }
    }
}

private struct IssueRow: View, ThemedView {
    @Environment(\.theme) var theme

    let issue: InfoPaneFacts.LinearIssueFacts
    let actions: InfoPaneLinearActions

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: InfoPaneLayout.columnSpacing) {
                InfoPaneIcon {
                    if let type = issue.stateType {
                        LinearIssueGlyph(stateType: type, colorHex: issue.stateColor)
                    } else {
                        Image(systemName: "circle.dotted").emphasis(.subtle)
                    }
                }
                Text(issue.identifier)
                    .fontWeight(.medium)
                    .layoutPriority(1)
                if let title = issue.title {
                    Text(title)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 4)
                Button {
                    if let url = issue.url { NSWorkspace.shared.open(url) }
                } label: {
                    Image(systemName: "arrow.up.right")
                }
                .buttonStyle(.plain)
                .emphasis(.secondary)
                .disabled(issue.url == nil)
                .help("Open in Linear")
                .plumeID(AccessibilityID.infoPaneLinearOpenButton, label: issue.identifier)
            }
            if !detail.isEmpty {
                HStack(spacing: InfoPaneLayout.columnSpacing) {
                    InfoPaneIcon { Color.clear }
                    Text(detail)
                        .lineLimit(2)
                        .emphasis(.subtle)
                }
            }
            HStack(spacing: 10) {
                InfoPaneIcon { Color.clear }
                if issue.role == .mentioned {
                    Button("Mark as working") { actions.promote(issue.identifier) }
                        .plumeID(AccessibilityID.infoPaneLinearMarkWorkingButton, label: issue.identifier)
                }
                Button(issue.role == .working ? "Unlink" : "Dismiss") { actions.unlink(issue.identifier) }
                    .plumeID(AccessibilityID.infoPaneLinearUnlinkButton, label: issue.identifier)
            }
            .buttonStyle(.plain)
            .emphasis(.secondary)
        }
        .padding(.vertical, InfoPaneLayout.rowVerticalPadding)
        .plumeID(AccessibilityID.infoPaneLinearIssueRow, label: issue.identifier, value: issue.statusWord ?? issue.stateName)
    }

    private var detail: String {
        var parts: [String] = []
        if let word = issue.statusWord { parts.append(word) }
        if let state = issue.stateName { parts.append(state) }
        if let assignee = issue.assignee { parts.append(assignee) }
        if let attribution = issue.attribution { parts.append(attribution) }
        if let hint = issue.sourceHint { parts.append(hint) }
        return parts.joined(separator: " · ")
    }
}

private struct LinkIssueField: View, ThemedView {
    @Environment(\.theme) var theme

    let actions: InfoPaneLinearActions

    @State private var text = ""
    @State private var showsError = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: InfoPaneLayout.columnSpacing) {
                TextField("PLUME-123 or URL", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .onSubmit(link)
                    .plumeID(AccessibilityID.infoPaneLinearLinkField, value: text, setValue: { text = $0 })
                Button("Link", action: link)
                    .controlSize(.small)
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                    .plumeID(AccessibilityID.infoPaneLinearLinkButton, invoke: link)
            }
            if showsError {
                Text("Not a Linear issue identifier")
                    .emphasis(.subtle)
            }
        }
        .onChange(of: text) { showsError = false }
    }

    private func link() {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        if actions.link(text) {
            text = ""
            showsError = false
        } else {
            showsError = true
        }
    }
}
