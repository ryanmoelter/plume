import AppKit
import SwiftUI

/// What the pull request section does to the task. Each closure acts on the
/// tab's task, so the section never sees it.
struct InfoPanePullRequestActions {
    let pin: (PullRequestReference) -> Void
    let unpin: (PullRequestReference) -> Void
    /// False when the text is not a pull request URL or `owner/repo#123`.
    let pinInput: (String) -> Bool

    static let none = InfoPanePullRequestActions(pin: { _ in }, unpin: { _ in }, pinInput: { _ in false })
}

/// Pull requests pinned to the task, then ones the conversation names.
struct LinkedPullRequestsSection: View, ThemedView {
    @Environment(\.theme) var theme

    let pullRequests: [InfoPaneFacts.LinkedPullRequestFacts]
    let actions: InfoPanePullRequestActions
    @Binding var showsMentioned: Bool

    @Environment(\.infoPaneIsOpen) private var isPaneOpen
    @State private var settings = AppSettings.shared
    @State private var showsPinPopover = false
    @State private var isHoveringAdd = false

    private static let title = "Pull Requests"
    private static let symbol = "arrow.triangle.pull"

    var body: some View {
        InfoPaneGroup(
            isGrouped: pullRequests.count > 1,
            expand: { settings.infoPaneLinkedPullRequestsExpanded = true }
        ) {
            if let only = pullRequests.first {
                LinkedPullRequestRow(linked: only, actions: actions) { showsPinPopover = true }
            } else {
                header(count: nil, isExpanded: false) { showsPinPopover = true }
            }
        } grouped: {
            grouped
        }
        .popover(isPresented: $showsPinPopover, arrowEdge: .bottom) {
            PinPullRequestPopover(actions: actions, isPresented: $showsPinPopover)
        }
        .preference(key: InfoPaneHoldsOpenKey.self, value: showsPinPopover)
        .onChange(of: isPaneOpen) { _, isOpen in
            if !isOpen { showsPinPopover = false }
        }
        .task(id: pullRequests.map(\.reference)) {
            LinkedPullRequestStore.shared.refresh(pullRequests.map(\.reference))
        }
    }

    private var grouped: some View {
        let isExpanded = settings.infoPaneLinkedPullRequestsExpanded
        let pinned = pullRequests.filter { $0.role == .pinned }
        let mentioned = pullRequests.filter { $0.role == .mentioned }
        return VStack(alignment: .leading, spacing: 0) {
            header(count: pullRequests.count, isExpanded: isExpanded) {
                withAnimation(InfoPaneLayout.sectionAnimation) { settings.infoPaneLinkedPullRequestsExpanded.toggle() }
            }
            if isExpanded {
                ForEach(pinned) { LinkedPullRequestRow(linked: $0, actions: actions) }
                if pinned.isEmpty {
                    ForEach(mentioned) { LinkedPullRequestRow(linked: $0, actions: actions) }
                } else if !mentioned.isEmpty {
                    mentionedGroup(mentioned)
                }
            }
        }
    }

    private func header(count: Int?, isExpanded: Bool, action: @escaping () -> Void) -> some View {
        InfoPaneGroupHeader(
            title: Self.title,
            count: count,
            isExpanded: isExpanded,
            accessibilityID: AccessibilityID.infoPaneLinkedPullRequestsToggle,
            accessibilityValue: count == nil ? "empty" : nil,
            suppressesWash: isHoveringAdd,
            reservesTrailingControl: true,
            action: action
        ) {
            Image(systemName: Self.symbol)
        }
        .overlay(alignment: .trailing) { addButton }
    }

    private var addButton: some View {
        Button { showsPinPopover = true } label: {
            Image(systemName: "plus")
                .frame(width: InfoPaneLayout.iconColumnWidth)
                .modifier(OverlaidControlWash(isHovering: isHoveringAdd))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(colors.selection)
        .plumeHover { isHoveringAdd = $0 }
        .help("Pin a pull request to this conversation")
        .plumeID(AccessibilityID.infoPaneLinkedPullRequestAddButton)
    }

    private func mentionedGroup(_ mentioned: [InfoPaneFacts.LinkedPullRequestFacts]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(InfoPaneLayout.sectionAnimation) { showsMentioned.toggle() }
            } label: {
                HStack(spacing: InfoPaneLayout.columnSpacing) {
                    // Holds the first column without filling the row's height.
                    InfoPaneIcon { DisclosureChevron(isExpanded: false).hidden() }
                    Text("Mentioned")
                    Text("\(mentioned.count)")
                    DisclosureChevron(isExpanded: showsMentioned)
                    Spacer(minLength: 0)
                }
                .emphasis(.subtle)
            }
            .buttonStyle(InfoPaneRowButtonStyle())
            .plumeID(
                AccessibilityID.infoPaneLinkedPullRequestsMentionedToggle,
                value: showsMentioned ? "expanded" : "collapsed"
            )

            if showsMentioned {
                ForEach(mentioned) { LinkedPullRequestRow(linked: $0, actions: actions) }
            }
        }
    }
}

/// Clicking opens the pull request. A mentioned one reads dimmer than a
/// pinned one.
private struct LinkedPullRequestRow: View, ThemedView {
    @Environment(\.theme) var theme
    @Environment(\.colorScheme) private var colorScheme

    let linked: InfoPaneFacts.LinkedPullRequestFacts
    let actions: InfoPanePullRequestActions
    /// Set on a lone row, which has no header to carry the pin button.
    var pinAnother: (() -> Void)?

    @State private var isHoveringMenu = false

    private var reference: PullRequestReference { linked.reference }
    private var label: String { "#\(reference.number)" }

    var body: some View {
        Button(action: open) {
            HStack(spacing: InfoPaneLayout.columnSpacing) {
                InfoPaneIcon { icon }
                Text(label)
                    .font(typography.caption.monoMedium)
                    .emphasis(linked.role == .pinned ? .primary : .secondary)
                Text(linked.pullRequest?.title ?? "\(reference.owner)/\(reference.repo)")
                    .emphasis(linked.role == .pinned ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                OverlaidControlSpace()
            }
        }
        .buttonStyle(InfoPaneRowButtonStyle(suppressesWash: isHoveringMenu))
        .contextMenu { menuItems }
        .help(linked.role == .pinned ? reference.url : "Mentioned in the conversation: \(reference.url)")
        .plumeID(
            AccessibilityID.infoPaneLinkedPullRequestRow,
            label: label,
            value: "\(linked.role == .pinned ? "pinned" : "mentioned") \(reference.url)",
            invoke: open
        )
        .overlay(alignment: .trailing) { actionsMenu }
    }

    @ViewBuilder
    private var icon: some View {
        if let pull = linked.pullRequest {
            Image(systemName: MentionAutocompleteView.symbol(for: pull))
                .foregroundStyle(MentionAutocompleteView.tint(for: pull, colorScheme: colorScheme))
        } else {
            Image(systemName: "arrow.triangle.pull")
                .emphasis(.secondary)
        }
    }

    private func open() {
        if let url = URL(string: reference.url) { ChatLinkOpener.open(.web(url)) }
    }

    private var actionsMenu: some View {
        Menu { menuItems } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(colors.selection)
        .frame(width: InfoPaneLayout.iconColumnWidth)
        .modifier(OverlaidControlWash(isHovering: isHoveringMenu))
        .plumeHover { isHoveringMenu = $0 }
        .help("Pull request actions")
        .plumeID(AccessibilityID.infoPaneLinkedPullRequestRowMenu, label: label)
    }

    @ViewBuilder
    private var menuItems: some View {
        let reference = reference
        if linked.role == .mentioned {
            item("Pin to Conversation", AccessibilityID.infoPaneLinkedPullRequestPinButton) { actions.pin(reference) }
            Divider()
        }
        item("Open on GitHub", AccessibilityID.infoPaneLinkedPullRequestOpenButton, perform: open)
        item("Copy URL", AccessibilityID.infoPaneLinkedPullRequestCopyButton) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(reference.url, forType: .string)
        }
        if linked.role == .pinned {
            Divider()
            item("Unpin from Conversation", AccessibilityID.infoPaneLinkedPullRequestUnpinButton) {
                actions.unpin(reference)
            }
        }
        if let pinAnother {
            Divider()
            item("Pin Another Pull Request…", AccessibilityID.infoPaneLinkedPullRequestPinAnotherButton) {
                // After the menu closes, so the popover has an anchor to present from.
                Task { @MainActor in pinAnother() }
            }
        }
    }

    private func item(_ title: String, _ id: String, perform: @escaping () -> Void) -> some View {
        Button(title, action: perform)
            .plumeID(id, label: label, invoke: perform)
    }
}

private struct PinPullRequestPopover: View, ThemedView {
    @Environment(\.theme) var theme

    let actions: InfoPanePullRequestActions
    @Binding var isPresented: Bool

    @State private var text = ""
    @State private var showsError = false
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                TextField("Pull request URL or owner/repo#123", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .focused($fieldFocused)
                    .onSubmit(pin)
                    .frame(width: 260)
                    .plumeID(AccessibilityID.infoPaneLinkedPullRequestPinField, value: text, setValue: { text = $0 })
                Button("Pin", action: pin)
                    .tint(colors.selection)
                    .plumeID(AccessibilityID.infoPaneLinkedPullRequestPinSubmit, invoke: pin)
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if showsError {
                Text("Not a GitHub pull request")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .onAppear { fieldFocused = true }
        .onChange(of: text) { showsError = false }
    }

    private func pin() {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        if actions.pinInput(text) {
            text = ""
            showsError = false
            isPresented = false
        } else {
            showsError = true
        }
    }
}
