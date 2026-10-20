import SwiftUI

/// The app's `Settings` scene (⌘,): a sidebar of panes, each its own view.
struct SettingsView: View {
    @AppStorage("settingsSelectedPane") private var selectedPaneRaw = SettingsPane.general.rawValue
    @State private var cliRefresh = 0
    /// Only ever set true. Setting a `FocusState` false resigns whatever is
    /// first responder at that moment.
    @FocusState private var isPaneListFocused: Bool

    private var displayedProviders: Set<AgentProviderKind>? {
        AgentCLIAvailability.shared.providers.map { AgentCLIInstallation.displayedProviders($0) }
    }

    private var selectedPane: SettingsPane {
        SettingsPane(rawValue: selectedPaneRaw) ?? .general
    }

    private func select(_ pane: SettingsPane) {
        selectedPaneRaw = pane.rawValue
        isPaneListFocused = true
    }

    private func moveSelection(by offset: Int) {
        let panes = SettingsPane.allCases
        guard let index = panes.firstIndex(of: selectedPane) else { return }
        let destination = index + offset
        guard panes.indices.contains(destination) else { return }
        selectedPaneRaw = panes[destination].rawValue
    }

    var body: some View {
        NavigationSplitView {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(SettingsPane.allCases) { pane in
                        Label(pane.title, systemImage: pane.symbol)
                            .labelStyle(SidebarIconLabelStyle())
                            .sidebarRow(isSelected: selectedPane == pane)
                            .onTapGesture { select(pane) }
                            .plumeID(AccessibilityID.settingsPane, label: pane.rawValue, value: selectedPane == pane ? "selected" : nil, invoke: { select(pane) })
                    }
                }
                .padding(.horizontal, SidebarMetrics.listHorizontalInset)
            }
            .focusable()
            .focused($isPaneListFocused)
            .focusEffectDisabled()
            .onMoveCommand { direction in
                switch direction {
                case .up: moveSelection(by: -1)
                case .down: moveSelection(by: 1)
                default: break
                }
            }
            .navigationSplitViewColumnWidth(180)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            detailView
        }
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .modifier(SettingsWindowModifier())
        .frame(minWidth: 680, minHeight: 460)
        .task(id: cliRefresh) {
            await AgentCLIAvailability.shared.refresh()
        }
        .onChange(of: displayedProviders, initial: true) { _, installed in
            if let installed { AppSettings.shared.reconcileInstalledProviders(installed) }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            cliRefresh += 1
        }
    }

    @ViewBuilder
    private var detailView: some View {
        switch selectedPane {
        case .general: GeneralSettingsPane()
        case .agents: AgentsSettingsPane()
        case .visuals: VisualsSettingsPane()
        case .keepAwake: KeepAwakeSettingsPane()
        case .shortcuts: ShortcutsSettingsPane()
        case .integrations: IntegrationsSettingsPane()
        case .updates: UpdatesSettingsPane()
        case .about: AboutSettingsPane()
        #if DEBUG
        case .debug: DebugSettingsPane()
        #endif
        }
    }
}

enum SettingsPane: String, CaseIterable, Identifiable {
    case general
    case agents
    case visuals
    case keepAwake
    case shortcuts
    case integrations
    case updates
    case about
    #if DEBUG
    case debug
    #endif

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .agents: "Agents"
        case .visuals: "Visuals"
        case .keepAwake: "Keep awake"
        case .shortcuts: "Shortcuts"
        case .integrations: "Integrations"
        case .updates: "Updates"
        case .about: "About"
        #if DEBUG
        case .debug: "Debug"
        #endif
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .agents: "person.2"
        case .visuals: "paintpalette"
        case .keepAwake: "cup.and.saucer"
        case .shortcuts: "keyboard"
        case .integrations: "puzzlepiece.extension"
        case .updates: "arrow.down.circle"
        case .about: "info.circle"
        #if DEBUG
        case .debug: "ladybug"
        #endif
        }
    }
}
