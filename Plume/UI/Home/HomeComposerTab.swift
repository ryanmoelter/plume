import Foundation

/// Home's composer as a tab: a `TaskTab` and `WorkTask` that are never
/// inserted into a store.
///
/// `ChatComposer` keys everything it keeps — the draft and its images in
/// `DraftStore`, accepted mentions in `MentionResolver`, the model, effort and
/// permission choices on the tab itself — by this tab, so Home gets all of it
/// without a composer of its own. Its folder is the project Home will start
/// in, which is where mentions look for files and remembered slash commands
/// come from.
@MainActor
final class HomeComposerTab {
    static let shared = HomeComposerTab(id: UUID())

    let task: WorkTask
    let tab: TaskTab
    /// Lives as long as the tab, so a start still in flight when Home
    /// unmounts reports its failure to the composer Home shows next.
    let model = HomeComposerModel()

    /// The settings' defaults the tab last took, which tell a choice the user
    /// made in the composer apart from one the settings made.
    private var followedDefaults: LaunchDefaults

    init(id: UUID, settings: AppSettings = .shared) {
        task = WorkTask(title: "Home", orderIndex: 0)
        tab = TaskTab(kind: .agent, orderIndex: 0, task: task)
        tab.id = id
        followedDefaults = LaunchDefaults(settings: settings)
        followedDefaults.apply(to: tab)
    }

    var launchChoices: TabLaunchChoices { TabLaunchChoices(tab) }

    /// Takes the settings' current provider, transport and Codex
    /// collaboration mode, unless the user has chosen others in the composer.
    func followDefaults(of settings: AppSettings = .shared) {
        let defaults = LaunchDefaults(settings: settings)
        guard defaults != followedDefaults, LaunchDefaults(tab: tab) == followedDefaults else { return }
        defaults.apply(to: tab)
        followedDefaults = defaults
    }

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

extension HomeComposerTab {
    /// What `TaskStore.createTask` gives a new task's tab from the settings.
    struct LaunchDefaults: Equatable {
        var providerID: String?
        var transportRaw: String?
        var codexCollaborationModeRaw: String

        init(settings: AppSettings) {
            let tab = TaskTab(kind: .agent, orderIndex: 0)
            TaskStore.applyDefaultLaunchSettings(to: tab, from: settings)
            self.init(tab: tab)
        }

        init(tab: TaskTab) {
            providerID = tab.providerID
            transportRaw = tab.transportRaw
            codexCollaborationModeRaw = tab.codexCollaborationModeRaw
        }

        func apply(to tab: TaskTab) {
            tab.providerID = providerID
            tab.transportRaw = transportRaw
            tab.codexCollaborationModeRaw = codexCollaborationModeRaw
        }
    }
}
