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

/// One row of the pull request section, whichever way the pull request
/// reached the task.
struct InfoPanePullRequestItem: Equatable, Identifiable {
    enum Role: String {
        /// The pull request of the branch the conversation runs on.
        case branch
        case pinned
        case mentioned
    }

    let id: String
    let role: Role
    let number: Int
    /// Nil until the forge has answered, and when it cannot.
    let summary: PullRequestSummary?
    let url: URL?
    /// Nil for the branch's own, which is never pinned.
    let reference: PullRequestReference?
    let forge: ForgeKind?
    /// What the title reads before the forge has answered.
    let placeholderTitle: String

    var title: String { summary?.title ?? placeholderTitle }

    /// The branch's own first, then pinned, then mentioned.
    static func items(
        branch: InfoPaneFacts.PullRequestFacts?,
        linked: [InfoPaneFacts.LinkedPullRequestFacts]
    ) -> [InfoPanePullRequestItem] {
        var items: [InfoPanePullRequestItem] = []
        if let branch, let summary = branch.summary {
            items.append(InfoPanePullRequestItem(
                id: "branch",
                role: .branch,
                number: summary.number,
                summary: summary,
                url: branch.url,
                reference: nil,
                forge: branch.forge,
                placeholderTitle: "#\(summary.number)"
            ))
        }
        for role in [Role.pinned, .mentioned] {
            let inRole = linked.filter { Role($0.role) == role }
            for linked in PullRequestStatusOrder.sorted(inRole, summary: { $0.pullRequest.map(PullRequestSummary.init) }) {
                let reference = linked.reference
                items.append(InfoPanePullRequestItem(
                    id: reference.id,
                    role: role,
                    number: reference.number,
                    summary: linked.pullRequest.map(PullRequestSummary.init),
                    url: URL(string: reference.url),
                    reference: reference,
                    forge: .github,
                    placeholderTitle: "\(reference.owner)/\(reference.repo)"
                ))
            }
        }
        return items
    }
}

/// Open, then draft, then unknown, then closed, then merged.
enum PullRequestStatusOrder {
    static func rank(_ summary: PullRequestSummary?) -> Int {
        guard let summary else { return 2 }
        switch summary.state {
        case .open: return summary.isDraft ? 1 : 0
        case .closed: return 3
        case .merged: return 4
        }
    }

    static func sorted<Element>(_ elements: [Element], summary: (Element) -> PullRequestSummary?) -> [Element] {
        elements.enumerated()
            .sorted { lhs, rhs in
                let (left, right) = (rank(summary(lhs.element)), rank(summary(rhs.element)))
                return left != right ? left < right : lhs.offset < rhs.offset
            }
            .map(\.element)
    }
}

private extension InfoPanePullRequestItem.Role {
    init(_ role: LinkedPullRequestRole) {
        switch role {
        case .pinned: self = .pinned
        case .mentioned: self = .mentioned
        }
    }
}

/// The branch's pull request, then pull requests pinned to the task, then
/// ones the conversation names.
struct PullRequestsSection: View, ThemedView {
    @Environment(\.theme) var theme

    let items: [InfoPanePullRequestItem]
    let actions: InfoPanePullRequestActions
    @Binding var showsMentioned: Bool

    @Environment(\.infoPaneIsOpen) private var isPaneOpen
    @State private var settings = AppSettings.shared
    @State private var showsPinPopover = false
    @State private var isHoveringAdd = false
    /// The item whose check list popover is showing.
    @State private var checksPopoverItemID: String?

    private static let title = "Pull Requests"

    private var linkedReferences: [PullRequestReference] { items.compactMap(\.reference) }

    var body: some View {
        InfoPaneGroup(
            isGrouped: items.count > 1,
            expand: { settings.infoPaneLinkedPullRequestsExpanded = true }
        ) {
            if let only = items.first {
                row(only, isLone: true)
            } else {
                header(count: nil, isExpanded: false) { showsPinPopover = true }
            }
        } grouped: {
            grouped
        }
        .popover(isPresented: $showsPinPopover, arrowEdge: .bottom) {
            PinPullRequestPopover(actions: actions, isPresented: $showsPinPopover)
        }
        .preference(key: InfoPaneHoldsOpenKey.self, value: showsPinPopover || checksPopoverItemID != nil)
        .onChange(of: isPaneOpen) { _, isOpen in
            if !isOpen {
                showsPinPopover = false
                checksPopoverItemID = nil
            }
        }
        .task(id: linkedReferences) {
            LinkedPullRequestStore.shared.refresh(linkedReferences)
        }
    }

    private var grouped: some View {
        let isExpanded = settings.infoPaneLinkedPullRequestsExpanded
        let leading = items.filter { $0.role != .mentioned }
        let mentioned = items.filter { $0.role == .mentioned }
        return InfoPaneBracketedSection(isExpanded: isExpanded) {
            header(count: items.count, isExpanded: isExpanded) {
                withAnimation(InfoPaneLayout.sectionAnimation) { settings.infoPaneLinkedPullRequestsExpanded.toggle() }
            }
        } rows: {
            if isExpanded {
                ForEach(leading) { row($0) }
                if leading.isEmpty {
                    ForEach(mentioned) { row($0) }
                } else if !mentioned.isEmpty {
                    mentionedGroup(mentioned)
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ item: InfoPanePullRequestItem, isLone: Bool = false) -> some View {
        PullRequestRow(item: item, isLone: isLone, actions: actions, pinAnother: isLone ? { showsPinPopover = true } : nil)
        if let summary = item.summary, summary.state == .open, !summary.checkContexts.isEmpty {
            PullRequestChecksRow(
                item: item,
                summary: summary,
                showsPopover: Binding(
                    get: { checksPopoverItemID == item.id },
                    set: { shows in
                        if shows {
                            checksPopoverItemID = item.id
                        } else if checksPopoverItemID == item.id {
                            checksPopoverItemID = nil
                        }
                    }
                )
            )
        }
    }

    private func header(count: Int?, isExpanded: Bool, action: @escaping () -> Void) -> some View {
        InfoPaneSectionHeader(
            title: Self.title,
            count: count,
            isExpanded: isExpanded,
            accessibilityID: AccessibilityID.infoPaneLinkedPullRequestsToggle,
            accessibilityValue: count == nil ? "empty" : nil,
            suppressesWash: isHoveringAdd,
            reservesTrailingControl: true,
            action: action
        )
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

    private func mentionedGroup(_ mentioned: [InfoPanePullRequestItem]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            InfoPaneSubgroupHeader(
                title: "Mentioned",
                count: mentioned.count,
                isExpanded: showsMentioned,
                accessibilityID: AccessibilityID.infoPaneLinkedPullRequestsMentionedToggle
            ) {
                withAnimation(InfoPaneLayout.sectionAnimation) { showsMentioned.toggle() }
            }

            if showsMentioned {
                ForEach(mentioned) { row($0) }
            }
        }
    }
}

/// Clicking opens the pull request. The open mark tops the trailing edge
/// and the actions menu sits under it. A mentioned one reads dimmer than the
/// rest.
private struct PullRequestRow: View, ThemedView {
    @Environment(\.theme) var theme

    let item: InfoPanePullRequestItem
    /// A row with no header above it, which names its forge in the icon
    /// column and moves its status beside the title.
    let isLone: Bool
    let actions: InfoPanePullRequestActions
    /// Set on a lone row, which has no header to carry the pin button.
    var pinAnother: (() -> Void)?

    @State private var isHoveringMenu = false

    private var label: String { "#\(item.number)" }

    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: InfoPaneLayout.columnSpacing) {
                InfoPaneIcon {
                    if isLone { forgeMark } else { leadingGlyph }
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        if isLone { leadingGlyph }
                        Text(item.title)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .emphasis(titleEmphasis)
                    }
                    Text(item.summary.map(PullRequestRowContent.detail) ?? label)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .emphasis(.subtle)
                }
                Spacer(minLength: 4)
                LinkOpenIcon()
                    .frame(width: InfoPaneLayout.iconColumnWidth)
                    .opacity(item.url == nil ? 0 : 1)
            }
        }
        .buttonStyle(InfoPaneRowButtonStyle(suppressesWash: isHoveringMenu))
        .contextMenu { menuItems }
        .help(help)
        .plumeID(
            item.role == .branch
                ? AccessibilityID.infoPanePullRequestRow
                : AccessibilityID.infoPaneLinkedPullRequestRow,
            label: label,
            value: "\(item.role.rawValue) \(item.url?.absoluteString ?? "")",
            invoke: open
        )
        .overlay(alignment: .bottomTrailing) { actionsMenu }
    }

    @ViewBuilder
    private var leadingGlyph: some View {
        if let summary = item.summary {
            PullRequestGlyphImage(glyph: PullRequestRowContent.leadingWithoutChecks(summary))
        } else {
            Image(systemName: "arrow.triangle.pull")
                .emphasis(titleEmphasis)
        }
    }

    @ViewBuilder
    private var forgeMark: some View {
        if let forge = item.forge, forge.markImageName != nil {
            ForgeMarkCell(forge: forge)
                .emphasis(titleEmphasis)
        } else {
            Image(systemName: "arrow.triangle.pull")
                .emphasis(titleEmphasis)
        }
    }

    private var titleEmphasis: Emphasis { item.role == .mentioned ? .secondary : .primary }

    private var help: String {
        PullRequestRowContent.tooltip(item.summary, number: item.number, forgeName: forgeName)
    }

    private var forgeName: String {
        item.forge == .gitlab ? "GitLab" : "GitHub"
    }

    private func open() {
        if let url = item.url { ChatLinkOpener.open(.web(url)) }
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
        .padding(.bottom, InfoPaneLayout.rowVerticalPadding)
        .help("Pull request actions")
        .plumeID(AccessibilityID.infoPaneLinkedPullRequestRowMenu, label: label)
    }

    /// The branch's own pull request keeps a pinned one's menu, with Unpin
    /// greyed out since the branch, not a pin, puts it here.
    @ViewBuilder
    private var menuItems: some View {
        let reference = item.reference
        if item.role == .mentioned, let reference {
            menuItem("Pin to Conversation", AccessibilityID.infoPaneLinkedPullRequestPinButton) { actions.pin(reference) }
            Divider()
        }
        menuItem("Open on \(forgeName)", AccessibilityID.infoPaneLinkedPullRequestOpenButton, isEnabled: item.url != nil, perform: open)
        menuItem("Copy URL", AccessibilityID.infoPaneLinkedPullRequestCopyButton, isEnabled: item.url != nil) {
            guard let url = item.url else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.absoluteString, forType: .string)
        }
        if item.role != .mentioned {
            Divider()
            menuItem("Unpin from Conversation", AccessibilityID.infoPaneLinkedPullRequestUnpinButton, isEnabled: reference != nil) {
                if let reference { actions.unpin(reference) }
            }
        }
        if let pinAnother {
            Divider()
            menuItem("Pin Another Pull Request…", AccessibilityID.infoPaneLinkedPullRequestPinAnotherButton) {
                // After the menu closes, so the popover has an anchor to present from.
                Task { @MainActor in pinAnother() }
            }
        }
    }

    private func menuItem(
        _ title: String,
        _ id: String,
        isEnabled: Bool = true,
        perform: @escaping () -> Void
    ) -> some View {
        Button(title, action: perform)
            .plumeID(id, label: label, invoke: perform)
            .disabled(!isEnabled)
    }
}

/// A pull request's checks under its row, folded to the rollup. Clicking
/// lists them one per line in a popover.
private struct PullRequestChecksRow: View, ThemedView {
    @Environment(\.theme) var theme

    let item: InfoPanePullRequestItem
    let summary: PullRequestSummary
    @Binding var showsPopover: Bool

    private var label: String { "#\(item.number)" }

    var body: some View {
        let entries = CheckListContent.entries(summary.checkContexts, ignored: summary.ignoredChecks)
        Button { showsPopover.toggle() } label: {
            HStack(spacing: InfoPaneLayout.columnSpacing) {
                InfoPaneIcon { Image(systemName: "checklist").hidden() }
                if let rollup = PullRequestChipContent.checkGlyph(summary.checkRollup) {
                    PullRequestGlyphImage(glyph: rollup)
                }
                Text(CheckListContent.summary(entries))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .emphasis(.subtle)
                Spacer(minLength: 4)
                Image(systemName: "info.circle")
                    .foregroundStyle(colors.selection)
                    .frame(width: InfoPaneLayout.iconColumnWidth)
            }
            .emphasis(.secondary)
        }
        .buttonStyle(InfoPaneRowButtonStyle())
        .help("Show every check")
        .plumeID(
            AccessibilityID.infoPanePullRequestChecksToggle,
            label: label,
            value: showsPopover ? "open" : "closed",
            invoke: { showsPopover.toggle() }
        )
        .popover(isPresented: $showsPopover, arrowEdge: .bottom) {
            PullRequestChecksPopover(title: "Checks on \(label)", entries: entries)
        }
    }
}

private struct PullRequestChecksPopover: View, ThemedView {
    @Environment(\.theme) var theme

    let title: String
    let entries: [CheckListEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .emphasis(.primary)
                Text(CheckListContent.summary(entries))
                    .emphasis(.subtle)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                        checkLine(entry)
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: 360)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(width: 320, alignment: .leading)
    }

    private func checkLine(_ entry: CheckListEntry) -> some View {
        let glyph = CheckListContent.glyph(for: entry)
        return HStack(spacing: 6) {
            PullRequestGlyphImage(glyph: glyph)
            Text(entry.name)
                .lineLimit(1)
                .truncationMode(.middle)
                .emphasis(entry.isIgnored ? .subtle : .secondary)
            if entry.isIgnored {
                Image(systemName: "eye.slash")
                    .emphasis(.subtle)
                    .help("Ignored while pending, in Settings ▸ Projects")
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .plumeID(
            AccessibilityID.infoPanePullRequestCheck,
            label: entry.name,
            value: entry.isIgnored ? "\(glyph.label) ignored" : glyph.label
        )
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
