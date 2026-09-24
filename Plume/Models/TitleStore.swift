import Foundation
import Observation

/// Where a tab's title came from, ranked by how much to trust it. A title is
/// accepted only when its source ranks at or above the one already recorded
/// — `TitleStore.setTitle(_:forTab:source:)` is where that rule lives.
enum TitleSource: String, Comparable {
    /// The opening user message, before anything has titled the conversation.
    case fallback
    /// The transcript's own `ai-title` line.
    case transcript
    /// A `generate_session_title` control response, or a terminal tab's own
    /// reported title.
    case reply

    private var rank: Int {
        switch self {
        case .fallback: 0
        case .transcript: 1
        case .reply: 2
        }
    }

    static func < (lhs: TitleSource, rhs: TitleSource) -> Bool { lhs.rank < rhs.rank }
}

/// The live title of every tab: Claude's own session title for agent tabs,
/// the terminal's title for terminal tabs.
///
/// An agent tab's title is whatever the transcript's latest `ai-title` line
/// says, falling back to the opening user message. Not every session gets an
/// `ai-title` — the interactive TUI writes one only sometimes, and a headless
/// conversation may not either, so `SessionTitleRequester` asks the CLI for
/// one. This store tracks each tab's `TitleSource` so a lower-ranked read
/// (the fallback, or a stale transcript re-read after a re-watch) can't
/// overwrite a higher-ranked title already in place.
///
/// In memory, like every other live-process fact; `TaskTab.title` holds a
/// debounced snapshot so a relaunch has something to show before any agent
/// reconnects.
@MainActor
@Observable
final class TitleStore {
    static let shared = TitleStore()

    private(set) var titles: [UUID: String] = [:]

    /// Each tab's current title source. See `TitleSource`.
    private var sources: [UUID: TitleSource] = [:]

    /// Called when a tab's title changes, so the snapshot can be persisted
    /// without this type depending on SwiftData.
    @ObservationIgnored var onTitleChanged: ((UUID, String, TitleSource) -> Void)?

    /// Called when a tab starts or switches to a different conversation, so
    /// a caller holding a persisted snapshot (`TaskTab.title`,
    /// `TaskTab.titleSource`) can clear it the same way.
    @ObservationIgnored var onConversationReset: ((UUID) -> Void)?

    init() {}

    func title(forTab id: UUID) -> String? {
        titles[id]
    }

    func source(forTab id: UUID) -> TitleSource? {
        sources[id]
    }

    /// Records a tab's source without touching the live title itself, so a
    /// source persisted from an earlier run (`TaskTab.titleSource`) is in
    /// place before anything re-reads a transcript — a fallback read landing
    /// first would otherwise be free to set the tab's title, with nothing
    /// recorded yet to outrank it.
    func seedSource(_ source: TitleSource, forTab id: UUID) {
        sources[id] = source
    }

    /// Lowers a tab's recorded source, never raising it — for a transport
    /// switch where the higher-ranked source can no longer arrive again (a
    /// `.reply` needs the headless control plane, which a switch to terminal
    /// turns off), so a source stuck above `source` would otherwise block
    /// every future update at that ceiling for good.
    func demoteSource(forTab id: UUID, to source: TitleSource) {
        guard let current = sources[id], current > source else { return }
        sources[id] = source
    }

    /// A title is accepted only when `source` ranks at or above the one
    /// already recorded: a fallback can set a tab's title but never replace
    /// a transcript or reply title, while a same-ranked source (a retitle)
    /// still wins.
    ///
    /// The source is recorded even when the text itself is unchanged, so a
    /// session resumed with a title already in hand is marked with its real
    /// source on first read rather than only on its next new value.
    func setTitle(_ title: String, forTab id: UUID, source: TitleSource) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard source >= (sources[id] ?? .fallback) else { return }
        sources[id] = source
        guard titles[id] != trimmed else { return }
        titles[id] = trimmed
        onTitleChanged?(id, trimmed, source)
    }

    /// Clears the live title and source for a tab about to show a different
    /// conversation, so the old one's title does not linger under the new
    /// one until something titles it.
    func beginNewConversation(forTab id: UUID) {
        titles.removeValue(forKey: id)
        sources.removeValue(forKey: id)
        onConversationReset?(id)
    }

    func forget(tabID: UUID) {
        titles.removeValue(forKey: tabID)
        sources.removeValue(forKey: tabID)
    }

    func reset() {
        titles.removeAll()
        sources.removeAll()
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

    /// What the UI shows for a task: the name the user gave it, else the
    /// representative tab's title.
    func displayTitle(for task: WorkTask) -> String {
        let name = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { return name }

        if let tab = Self.representativeTab(of: task) {
            if let live = titles[tab.id], !live.isEmpty { return live }
            if let stored = tab.title, !stored.isEmpty { return stored }
        }
        return "New task"
    }
}
