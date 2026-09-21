import Foundation
import Observation

/// The live title of every tab: Claude's own session title for agent tabs,
/// the terminal's title for terminal tabs.
///
/// An agent tab's title is whatever the transcript's latest `ai-title` line
/// says, falling back to the opening user message. The interactive TUI writes
/// that line itself; a headless conversation only gets one because
/// `SessionTitleRequester` asks the CLI for it.
///
/// In memory, like every other live-process fact; `TaskTab.title` holds a
/// debounced snapshot so a relaunch has something to show before any agent
/// reconnects.
@MainActor
@Observable
final class TitleStore {
    static let shared = TitleStore()

    private(set) var titles: [UUID: String] = [:]

    /// Called when a tab's title changes, so the snapshot can be persisted
    /// without this type depending on SwiftData.
    @ObservationIgnored var onTitleChanged: ((UUID, String) -> Void)?

    init() {}

    func title(forTab id: UUID) -> String? {
        titles[id]
    }

    func setTitle(_ title: String, forTab id: UUID) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, titles[id] != trimmed else { return }
        titles[id] = trimmed
        onTitleChanged?(id, trimmed)
    }

    func forget(tabID: UUID) {
        titles.removeValue(forKey: tabID)
    }

    func reset() {
        titles.removeAll()
    }

    /// The tab whose title stands in for the task: the last agent tab the user
    /// focused, else the selected tab, else the first.
    ///
    /// Preferring the last-focused *agent* tab keeps the sidebar showing what
    /// the agent is doing when the user dips into a terminal tab.
    static func representativeTab(of task: WorkTask) -> TaskTab? {
        let tabs = task.orderedTabs
        if let id = task.lastFocusedAgentTabID, let tab = tabs.first(where: { $0.id == id }) {
            return tab
        }
        if let id = task.selectedTabID, let tab = tabs.first(where: { $0.id == id }) {
            return tab
        }
        return tabs.first
    }

    /// What the sidebar shows for a task: the name the user gave it, else the
    /// representative tab's title.
    func displayTitle(for task: WorkTask) -> String {
        let name = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { return name }

        if let tab = Self.representativeTab(of: task) {
            if let live = titles[tab.id], !live.isEmpty { return live }
            if let stored = tab.title, !stored.isEmpty { return stored }
        }
        return "Untitled"
    }
}
