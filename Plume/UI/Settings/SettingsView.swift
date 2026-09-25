import SwiftUI

/// The app's `Settings` scene (⌘,): a sidebar of panes, each its own view.
struct SettingsView: View {
    @AppStorage("settingsSelectedPane") private var selectedPaneRaw = SettingsPane.general.rawValue
    @State private var cliRefresh = 0

    private var displayedProviders: Set<AgentProviderKind>? {
        AgentCLIAvailability.shared.providers.map { AgentCLIInstallation.displayedProviders($0) }
    }

    private var selectedPane: Binding<SettingsPane?> {
        Binding(
            get: { SettingsPane(rawValue: selectedPaneRaw) ?? .general },
            set: { if let newValue = $0 { selectedPaneRaw = newValue.rawValue } }
        )
    }

    var body: some View {
        NavigationSplitView {
            List(selection: selectedPane) {
                ForEach(SettingsPane.allCases) { pane in
                    Label(pane.title, systemImage: pane.symbol)
                        .plumeID(AccessibilityID.settingsPane, label: pane.rawValue, invoke: { selectedPaneRaw = pane.rawValue })
                        // Outermost: a List reads the tag only from the row's top-level view.
                        .tag(pane)
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
        switch SettingsPane(rawValue: selectedPaneRaw) ?? .general {
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
