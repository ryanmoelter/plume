import Foundation
import SwiftData
import Testing
@testable import Plume

/// Home's composer runs as a tab that is never in a store. What it sends
/// reaches the new task as the plan's message, with mentions expanded under
/// the tab's ID, its images, and the model, effort and permission choices
/// made on Home's tab, which the new task's tab launches with. Its provider,
/// transport and Codex collaboration mode follow the settings until the user
/// picks others.
@MainActor
struct HomeComposerTabTests {
    private let defaults: UserDefaults
    private let plume = HomeProject(path: "/repos/plume", isRepository: true)

    init() throws {
        defaults = try #require(UserDefaults(suiteName: "HomeComposerTabTests-\(UUID().uuidString)"))
    }

    // MARK: Identity

    @Test func theTabCarriesTheIDAndIsNeverInAStore() {
        let id = UUID()
        let home = HomeComposerTab(id: id)
        #expect(home.tab.id == id)
        #expect(home.tab.kind == .agent)
        #expect(home.tab.modelContext == nil)
        #expect(home.task.modelContext == nil)
    }

    @Test func theDirectoryIsTheChosenProject() {
        let home = HomeComposerTab(id: UUID())
        home.setDirectory(plume.path)
        #expect(TabDirectoryStore().directory(for: home.tab) == plume.path)
    }

    // MARK: Following the settings

    private func settings() -> AppSettings {
        AppSettings(defaults: defaults, domainName: "", initialAccentPaletteSlot: { nil })
    }

    @Test func theTabStartsOnTheSettingsDefaults() {
        let settings = settings()
        settings.defaultProvider = .codex
        settings.defaultCodexCollaborationMode = .plan
        let home = HomeComposerTab(id: UUID(), settings: settings)
        #expect(home.tab.provider == .codex)
        #expect(home.tab.codexCollaborationMode == .plan)
    }

    @Test func aChangedSettingReachesAnUntouchedTab() {
        let settings = settings()
        settings.defaultProvider = .claudeCode
        let home = HomeComposerTab(id: UUID(), settings: settings)
        settings.defaultProvider = .codex
        settings.defaultCodexCollaborationMode = .plan
        home.followDefaults(of: settings)

        let fresh = TaskTab(kind: .agent, orderIndex: 0)
        TaskStore.applyDefaultLaunchSettings(to: fresh, from: settings)
        #expect(home.tab.provider == .codex)
        #expect(home.tab.codexCollaborationMode == .plan)
        #expect(home.tab.transport == fresh.transport)
    }

    @Test func aProviderPickedInTheComposerOutlivesASettingsChange() {
        let settings = settings()
        settings.defaultProvider = .claudeCode
        let home = HomeComposerTab(id: UUID(), settings: settings)
        home.tab.provider = .codex
        settings.defaultCodexCollaborationMode = .plan
        settings.defaultProvider = .claudeCode
        settings.defaultAgentTransport = .terminal
        home.followDefaults(of: settings)
        #expect(home.tab.provider == .codex)
        #expect(home.tab.codexCollaborationMode == .default)
    }

    // MARK: Launch choices

    private func choosing(on tab: TaskTab) {
        let settings = ComposerSettings(session: nil, tab: tab, defaults: .init(permissionMode: nil, effort: .medium, model: nil))
        settings.setModel(AgentModel(unrecognizedID: "claude-test-model"))
        settings.setEffort(.high)
        settings.setPermissionMode(.acceptEdits)
    }

    @Test func choicesCarryFromOneTabToAnother() {
        let home = HomeComposerTab(id: UUID())
        choosing(on: home.tab)
        let fresh = TaskTab(kind: .agent, orderIndex: 0)
        home.launchChoices.apply(to: fresh)
        #expect(fresh.modelRaw == "claude-test-model")
        #expect(fresh.isModelUserChosen)
        #expect(fresh.effort == .high)
        #expect(fresh.isEffortUserChosen)
        #expect(fresh.permissionMode == .acceptEdits)
        #expect(fresh.provider == home.tab.provider)
        #expect(fresh.transport == home.tab.transport)
        #expect(TabLaunchChoices(fresh) == home.launchChoices)
    }

    // MARK: Send

    private func resolver() -> MentionResolver {
        MentionResolver(dependencies: .init(
            linearIssue: { _ in nil },
            lookUpLinear: { _ in },
            pullRequest: { _, _ in nil },
            fileIsDirectory: { _ in nil },
            homeDirectory: "/Users/test"
        ))
    }

    @Test func theSendCarriesExpandedTextImagesAndChoicesIntoThePlan() throws {
        let home = HomeComposerTab(id: UUID())
        choosing(on: home.tab)
        let mentions = resolver()
        mentions.remember(
            ResolvedMention(target: "https://linear.app/acme/issue/DROID-1", title: nil, state: .file(isDirectory: false)),
            for: .linear(identifier: "DROID-1"),
            tabID: home.tab.id
        )
        let typed = "Fix @DROID-1 now"
        let image = ChatImage(mediaType: "image/png", base64: "iVBORw0KGgo=")
        let message = ComposerHandOff.Message(
            typedText: typed,
            blocks: [.text(mentions.expandingReferences(in: typed, tabID: home.tab.id)), .image(image)]
        )
        let catalog = HomeDestinationCatalog(projects: [plume])
        let destination = HomeDestination(groupID: nil, projectPath: plume.path, workspace: .newWorktree)

        let plan = try #require(catalog.plan(
            for: destination, sending: message, choices: home.launchChoices,
            branchPrefix: "ryanm/", branchSuffix: "beef"
        ))

        #expect(plan.message == "Fix [DROID-1](https://linear.app/acme/issue/DROID-1) now")
        #expect(plan.images == [image])
        #expect(plan.choices == home.launchChoices)
        #expect(plan.choices?.modelRaw == "claude-test-model")
        #expect(plan.workspace == .newWorktree(repository: plume.path, branch: "ryanm/fix-droid-1-now-beef"))
        #expect(plan.blocks == [.text(plan.message), .image(image)])
    }

    @Test func anImageAloneIsWorthAPlan() {
        let catalog = HomeDestinationCatalog(projects: [plume])
        let destination = HomeDestination(groupID: nil, projectPath: plume.path, workspace: .projectFolder)
        let message = ComposerHandOff.Message(
            typedText: "", blocks: [.text(""), .image(ChatImage(mediaType: "image/png", base64: "AA=="))]
        )
        #expect(catalog.plan(for: destination, sending: message, choices: nil, branchPrefix: "") != nil)
    }

    @Test func theNewTaskTabLaunchesWithThePlansChoices() throws {
        let container = try ModelContainer(
            for: Schema([TaskGroup.self, WorkTask.self, TaskTab.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)
        let home = HomeComposerTab(id: UUID())
        choosing(on: home.tab)
        let plan = HomeTaskPlan(
            groupID: nil,
            workspace: .directory(path: plume.path, repoPath: plume.path),
            message: "Hi",
            choices: home.launchChoices
        )
        let task = HomeTaskStarter.createTask(
            for: plan, directory: plume.path, in: context, recentFolders: defaults
        )
        let tab = try #require(task.orderedTabs.first)
        #expect(TabLaunchChoices(tab) == home.launchChoices)
        #expect(tab.id != home.tab.id)
    }
}
