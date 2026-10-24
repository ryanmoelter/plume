import AppKit
import SwiftUI

/// What the Linear section does to the task. Each closure acts on the tab's
/// task, so the section never sees it.
struct InfoPaneLinearActions {
    let promote: (String) -> Void
    /// Demotes the issue to mentioned.
    let unlink: (String) -> Void
    /// Folds a lingering mentioned issue into the Mentioned section early.
    let moveToMentioned: (String) -> Void
    /// False when the text is not a Linear issue identifier or URL.
    let link: (String) -> Bool

    static let none = InfoPaneLinearActions(
        promote: { _ in }, unlink: { _ in }, moveToMentioned: { _ in }, link: { _ in false }
    )
}

struct LinearIssuesSection: View, ThemedView {
    @Environment(\.theme) var theme

    let linear: InfoPaneFacts.LinearFacts?
    let actions: InfoPaneLinearActions
    @Binding var showsMentioned: Bool

    @State private var settings = AppSettings.shared
    @State private var showsLinkPopover = false
    @State private var isHoveringAdd = false
    @State private var showsAllIssues = false

    var body: some View {
        if let linear {
            let isExpanded = settings.infoPaneLinearExpanded && !linear.isEmpty
            VStack(alignment: .leading, spacing: 0) {
                header(linear, isExpanded: isExpanded)
                if isExpanded {
                    let cap = LinearIssueCap.layout(total: linear.main.count, isExpanded: showsAllIssues)
                    ForEach(linear.main.prefix(cap.visibleCount)) {
                        IssueRow(issue: $0, showsBubble: $0.role == .mentioned, actions: actions)
                    }
                    if let title = cap.toggleTitle, let symbol = cap.toggleSymbol {
                        capToggle(title: title, symbol: symbol)
                    }
                    if !linear.mentioned.isEmpty {
                        mentioned(linear.mentioned)
                    }
                }
            }
        }
    }

    private func header(_ linear: InfoPaneFacts.LinearFacts, isExpanded: Bool) -> some View {
        let hoveringAdd = isHoveringAdd && !linear.isEmpty
        return Button {
            if linear.isEmpty {
                showsLinkPopover = true
            } else {
                withAnimation(InfoPaneLayout.sectionAnimation) { settings.infoPaneLinearExpanded.toggle() }
            }
        } label: {
            HStack(spacing: InfoPaneLayout.columnSpacing) {
                InfoPaneIcon { LinearLogo() }
                Text("Linear")
                if !isExpanded, linear.workingCount > 0 {
                    Text("\(linear.workingCount)")
                }
                if !linear.isEmpty {
                    DisclosureChevron(isExpanded: isExpanded)
                }
                Spacer(minLength: 0)
                OverlaidControlSpace()
            }
            .emphasis(.secondary)
        }
        .buttonStyle(InfoPaneRowButtonStyle(suppressesWash: hoveringAdd))
        .plumeID(AccessibilityID.infoPaneLinearToggle, value: linear.isEmpty ? "empty" : isExpanded ? "expanded" : "collapsed")
        .overlay(alignment: .trailing) {
            Button { showsLinkPopover = true } label: {
                Image(systemName: "plus")
                    .frame(width: InfoPaneLayout.iconColumnWidth)
                    .modifier(OverlaidControlWash(isHovering: hoveringAdd))
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.colors.selection)
            .plumeHover { isHoveringAdd = $0 }
            .help("Pin a Linear issue to this conversation")
            .plumeID(AccessibilityID.infoPaneLinearAddButton)
            .popover(isPresented: $showsLinkPopover, arrowEdge: .bottom) {
                LinkIssuePopover(actions: actions, isPresented: $showsLinkPopover)
            }
        }
    }

    private func capToggle(title: String, symbol: String) -> some View {
        Button {
            withAnimation(InfoPaneLayout.sectionAnimation) { showsAllIssues.toggle() }
        } label: {
            HStack(spacing: InfoPaneLayout.columnSpacing) {
                InfoPaneIcon { Image(systemName: symbol) }
                Text(title)
                Spacer(minLength: 0)
            }
            .emphasis(.subtle)
        }
        .buttonStyle(InfoPaneRowButtonStyle())
        .plumeID(AccessibilityID.infoPaneLinearCapToggle, value: showsAllIssues ? "expanded" : "collapsed")
    }

    private func mentioned(_ issues: [InfoPaneFacts.LinearIssueFacts]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(InfoPaneLayout.sectionAnimation) { showsMentioned.toggle() }
            } label: {
                HStack(spacing: InfoPaneLayout.columnSpacing) {
                    // Holds the first column without filling the row's height.
                    InfoPaneIcon { DisclosureChevron(isExpanded: false).hidden() }
                    Text("Mentioned")
                    Text("\(issues.count)")
                    DisclosureChevron(isExpanded: showsMentioned)
                    Spacer(minLength: 0)
                }
                .emphasis(.subtle)
            }
            .buttonStyle(InfoPaneRowButtonStyle())
            .plumeID(AccessibilityID.infoPaneLinearMentionedToggle, value: showsMentioned ? "expanded" : "collapsed")

            if showsMentioned {
                ForEach(issues) { IssueRow(issue: $0, showsBubble: false, actions: actions) }
            }
        }
    }
}

/// Clicking opens the issue in Linear. A mentioned issue, or one with no URL
/// yet, opens its menu instead, since there is nothing linked to open.
private struct IssueRow: View, ThemedView {
    @Environment(\.theme) var theme

    let issue: InfoPaneFacts.LinearIssueFacts
    /// Marks a mentioned issue lingering among the working ones.
    let showsBubble: Bool
    let actions: InfoPaneLinearActions

    @State private var isHoveringMenu = false

    var body: some View {
        Button(action: activate) {
            HStack(alignment: .top, spacing: InfoPaneLayout.columnSpacing) {
                InfoPaneIcon { icon }
                VStack(alignment: .leading, spacing: 2) {
                    Text(issue.title ?? issue.identifier)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .emphasis(showsBubble ? .secondary : .primary)
                    detailLine
                }
                Spacer(minLength: 4)
                OverlaidControlSpace()
            }
        }
        .buttonStyle(InfoPaneRowButtonStyle(suppressesWash: isHoveringMenu))
        .contextMenu { menuItems }
        .help(issue.title.map { "\(issue.identifier) \($0)" } ?? issue.identifier)
        .plumeID(
            AccessibilityID.infoPaneLinearIssueRow,
            label: issue.identifier,
            value: issue.statusWord ?? issue.stateName,
            invoke: activate
        )
        .overlay(alignment: .topTrailing) { actionsMenu }
    }

    @ViewBuilder
    private var icon: some View {
        if showsBubble {
            Image(systemName: "questionmark.bubble").emphasis(.secondary)
        } else if let type = issue.stateType {
            LinearIssueGlyph(stateType: type, colorHex: issue.stateColor)
        } else {
            Image(systemName: "circle.dotted").emphasis(.subtle)
        }
    }

    @ViewBuilder
    private var detailLine: some View {
        let details = detailParts.joined(separator: " · ")
        if issue.title != nil || !details.isEmpty {
            Text([issue.title != nil ? issue.identifier : nil, details.isEmpty ? nil : details]
                .compactMap { $0 }
                .joined(separator: " · "))
                .lineLimit(1)
                .truncationMode(.tail)
                .emphasis(.subtle)
        }
    }

    private var detailParts: [String] {
        [issue.statusWord, issue.stateName, issue.assignee, issue.attribution].compactMap { $0 }
    }

    private func activate() {
        if issue.role == .working, let url = issue.url {
            NSWorkspace.shared.open(url)
        } else {
            // After the click's own event handling, which a modal menu
            // tracking loop would otherwise run inside.
            Task { @MainActor in
                IssueMenu.make(menuEntries).popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
            }
        }
    }

    private var actionsMenu: some View {
        Menu { menuItems } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(theme.colors.selection)
        .frame(width: InfoPaneLayout.iconColumnWidth)
        .modifier(OverlaidControlWash(isHovering: isHoveringMenu))
        .plumeHover { isHoveringMenu = $0 }
        .padding(.top, InfoPaneLayout.rowVerticalPadding)
        .help("Linear issue actions")
        .plumeID(AccessibilityID.infoPaneLinearRowMenu, label: issue.identifier)
    }

    @ViewBuilder
    private var menuItems: some View {
        ForEach(Array(menuEntries.enumerated()), id: \.offset) { _, entry in
            switch entry {
            case .divider:
                Divider()
            case .action(let title, let id, let isEnabled, let perform):
                Button(title, action: perform)
                    .plumeID(id, label: issue.identifier, invoke: perform)
                    .disabled(!isEnabled)
            }
        }
    }

    private var menuEntries: [IssueMenu.Entry] {
        let identifier = issue.identifier
        var entries: [IssueMenu.Entry] = []
        if issue.role == .mentioned {
            entries.append(.action("Pin to Conversation", AccessibilityID.infoPaneLinearLinkToConversationButton, isEnabled: true) {
                actions.promote(identifier)
            })
            entries.append(.divider)
        }
        entries.append(.action("Open in Linear", AccessibilityID.infoPaneLinearOpenButton, isEnabled: issue.url != nil) {
            if let url = issue.url { NSWorkspace.shared.open(url) }
        })
        entries.append(.action("Copy Identifier", AccessibilityID.infoPaneLinearCopyButton, isEnabled: true) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(identifier, forType: .string)
        })
        if issue.role == .working {
            entries.append(.divider)
            entries.append(.action("Unpin from Conversation", AccessibilityID.infoPaneLinearUnlinkButton, isEnabled: true) {
                actions.unlink(identifier)
            })
        } else if showsBubble {
            entries.append(.divider)
            entries.append(.action("Move to Mentioned", AccessibilityID.infoPaneLinearMoveToMentionedButton, isEnabled: true) {
                actions.moveToMentioned(identifier)
            })
        }
        return entries
    }
}

/// One issue's actions, drawn both as SwiftUI menu items and as the AppKit
/// menu a row click pops up.
private enum IssueMenu {
    enum Entry {
        case action(String, String, isEnabled: Bool, perform: () -> Void)
        case divider
    }

    @MainActor static func make(_ entries: [Entry]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for entry in entries {
            switch entry {
            case .divider:
                menu.addItem(.separator())
            case .action(let title, _, let isEnabled, let perform):
                let item = ClosureMenuItem(title: title, perform: perform)
                item.isEnabled = isEnabled
                menu.addItem(item)
            }
        }
        return menu
    }
}

private final class ClosureMenuItem: NSMenuItem {
    private let perform: () -> Void

    init(title: String, perform: @escaping () -> Void) {
        self.perform = perform
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func invoke() { perform() }
}

/// Keeps a row's content clear of the control laid over its trailing edge.
private struct OverlaidControlSpace: View {
    var body: some View {
        Color.clear.frame(width: InfoPaneLayout.iconColumnWidth, height: 1)
    }
}

/// The hover wash of a control laid over a row, which replaces the row's own.
struct OverlaidControlWash: ViewModifier, ThemedView {
    @Environment(\.theme) var theme
    let isHovering: Bool

    func body(content: Content) -> some View {
        content
            .padding(3)
            .background(isHovering ? colors.surfaceTint : Color.clear, in: .rect(cornerRadius: 4))
            .padding(-3)
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
                Button("Pin", action: link)
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
