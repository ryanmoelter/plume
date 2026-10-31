import Foundation

/// Home's composer as a tab: a `TaskTab` and `WorkTask` that are never
/// inserted into a store, under an ID that stays the same across launches.
///
/// `ChatComposer` keys everything it keeps — the draft and its images in
/// `DraftStore`, accepted mentions in `MentionResolver`, the model, effort and
/// permission choices on the tab itself — by this tab, so Home gets all of it
/// without a composer of its own. Its folder is the project Home will start
/// in, which is where mentions look for files and remembered slash commands
/// come from.
@MainActor
final class HomeComposerTab {
    static let userDefaultsKey = "homeComposerTabID"
    static let shared = HomeComposerTab(id: storedID())

    let task: WorkTask
    let tab: TaskTab

    init(id: UUID, settings: AppSettings = .shared) {
        task = WorkTask(title: "Home", orderIndex: 0)
        tab = TaskTab(kind: .agent, orderIndex: 0, task: task)
        tab.id = id
        tab.provider = settings.defaultProvider
        tab.transport = tab.provider.resolvedTransport(preferring: settings.defaultAgentTransport)
        if tab.provider == .codex {
            tab.codexCollaborationMode = settings.defaultCodexCollaborationMode
        }
    }

    static func storedID(in defaults: UserDefaults = .standard) -> UUID {
        if let raw = defaults.string(forKey: userDefaultsKey), let id = UUID(uuidString: raw) { return id }
        let id = UUID()
        defaults.set(id.uuidString, forKey: userDefaultsKey)
        return id
    }

    var launchChoices: TabLaunchChoices { TabLaunchChoices(tab) }

    func setDirectory(_ path: String?) {
        guard tab.workingDirectoryPath != path else { return }
        tab.workingDirectoryPath = path
    }

    /// The draft is already cleared by the composer; its mentions were only
    /// needed to expand it.
    func didStartTask() {
        MentionResolver.shared.forgetTab(tab.id)
    }
}
