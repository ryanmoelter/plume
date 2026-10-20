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

    @State private var showsLinkPopover = false

    var body: some View {
        if let linear {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: InfoPaneLayout.columnSpacing) {
                    InfoPaneIcon { LinearLogo() }
                    Text("Linear")
                    Spacer(minLength: 0)
                    Button { showsLinkPopover = true } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.colors.selection)
                    .help("Link a Linear issue")
                    .plumeID(AccessibilityID.infoPaneLinearAddButton)
                    .popover(isPresented: $showsLinkPopover, arrowEdge: .bottom) {
                        LinkIssuePopover(actions: actions, isPresented: $showsLinkPopover)
                    }
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
                if linear.issues.isEmpty {
                    HStack(spacing: InfoPaneLayout.columnSpacing) {
                        InfoPaneIcon { Color.clear }
                        Text("No linked issues").emphasis(.subtle)
                    }
                    .padding(.vertical, InfoPaneLayout.rowVerticalPadding)
                }
            }
        }
    }
}

private struct IssueRow: View, ThemedView {
    @Environment(\.theme) var theme

    let issue: InfoPaneFacts.LinearIssueFacts
    let actions: InfoPaneLinearActions

    var body: some View {
        HStack(alignment: .top, spacing: InfoPaneLayout.columnSpacing) {
            InfoPaneIcon {
                if let type = issue.stateType {
                    LinearIssueGlyph(stateType: type, colorHex: issue.stateColor)
                } else {
                    Image(systemName: "circle.dotted").emphasis(.subtle)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: InfoPaneLayout.columnSpacing) {
                    Text(issue.identifier)
                        .fontWeight(.medium)
                        .layoutPriority(1)
                    if let title = issue.title {
                        Text(title)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                if !detail.isEmpty {
                    Text(detail)
                        .lineLimit(2)
                        .emphasis(.subtle)
                }
            }
            Spacer(minLength: 4)
            actionsMenu
        }
        .padding(.vertical, InfoPaneLayout.rowVerticalPadding)
        .plumeID(AccessibilityID.infoPaneLinearIssueRow, label: issue.identifier, value: issue.statusWord ?? issue.stateName)
    }

    private var actionsMenu: some View {
        Menu {
            Button("Open in Linear") {
                if let url = issue.url { NSWorkspace.shared.open(url) }
            }
            .plumeID(AccessibilityID.infoPaneLinearOpenButton, label: issue.identifier)
            .disabled(issue.url == nil)
            Button("Copy Identifier") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(issue.identifier, forType: .string)
            }
            if issue.role == .mentioned {
                Button("Mark as Working") { actions.promote(issue.identifier) }
                    .plumeID(AccessibilityID.infoPaneLinearMarkWorkingButton, label: issue.identifier)
            }
            Divider()
            Button(issue.role == .working ? "Unlink" : "Dismiss") { actions.unlink(issue.identifier) }
                .plumeID(AccessibilityID.infoPaneLinearUnlinkButton, label: issue.identifier)
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(theme.colors.selection)
        .help("Linear issue actions")
        .plumeID(AccessibilityID.infoPaneLinearRowMenu, label: issue.identifier)
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

private struct LinkIssuePopover: View, ThemedView {
    @Environment(\.theme) var theme

    let actions: InfoPaneLinearActions
    @Binding var isPresented: Bool

    @State private var text = ""
    @State private var showsError = false
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                TextField("PLUME-123 or issue URL", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .focused($fieldFocused)
                    .onSubmit(link)
                    .frame(width: 220)
                    .plumeID(AccessibilityID.infoPaneLinearLinkField, value: text, setValue: { text = $0 })
                Button("Link", action: link)
                    .tint(theme.colors.selection)
                    .plumeID(AccessibilityID.infoPaneLinearLinkButton, invoke: link)
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if showsError {
                Text("Not a Linear issue identifier")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .onAppear { fieldFocused = true }
        .onChange(of: text) { showsError = false }
    }

    private func link() {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        if actions.link(text) {
            text = ""
            showsError = false
            isPresented = false
        } else {
            showsError = true
        }
    }
}
