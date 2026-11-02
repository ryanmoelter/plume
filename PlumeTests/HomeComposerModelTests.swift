import Foundation
import Testing
@testable import Plume

/// Home's project list re-resolves every folder on each refresh, so a folder
/// deleted or made a repository since the last one shows as it is now, and a
/// folder added from the open panel joins the same list.
@MainActor
struct HomeComposerModelTests {
    /// Stands in for `git`: what each folder resolves to right now.
    private final class Disk: @unchecked Sendable {
        var projects: [String: HomeProject] = [:]

        func resolve(_ paths: [String]) -> [String: HomeProject?] {
            Dictionary(uniqueKeysWithValues: paths.map { ($0, projects[$0]) })
        }
    }

    private let disk = Disk()

    private func model() -> HomeComposerModel {
        HomeComposerModel(resolve: { [disk] in disk.resolve($0) }, configuredFolders: { [] })
    }

    private func inputs(paths: [String]) -> HomeComposerInputs {
        HomeComposerInputs(groups: [], tasks: paths.map { path in
            .init(id: UUID(), groupID: nil, path: path, workspaceKindRaw: "", createdAt: Date())
        })
    }

    @Test func aDeletedFolderLeavesTheList() async {
        disk.projects["/repos/plume"] = HomeProject(path: "/repos/plume", isRepository: true)
        disk.projects["/docs/notes"] = HomeProject(path: "/docs/notes", isRepository: false)
        let model = model()
        let inputs = inputs(paths: ["/repos/plume", "/docs/notes"])
        await model.refresh(inputs, recentTaskID: nil)
        #expect(model.catalog.projects.map(\.path) == ["/docs/notes", "/repos/plume"])

        disk.projects["/docs/notes"] = nil
        await model.refresh(inputs, recentTaskID: nil)
        #expect(model.catalog.projects.map(\.path) == ["/repos/plume"])
    }

    @Test func aFolderMadeARepositoryOffersWorktrees() async {
        disk.projects["/docs/notes"] = HomeProject(path: "/docs/notes", isRepository: false)
        let model = model()
        let inputs = inputs(paths: ["/docs/notes"])
        await model.refresh(inputs, recentTaskID: nil)
        #expect(model.catalog.project(at: "/docs/notes")?.isRepository == false)

        disk.projects["/docs/notes"] = HomeProject(path: "/docs/notes", isRepository: true)
        await model.refresh(inputs, recentTaskID: nil)
        #expect(model.catalog.project(at: "/docs/notes")?.isRepository == true)
    }

    @Test func anAddedFolderJoinsTheListAndIsChosen() async {
        disk.projects["/repos/plume"] = HomeProject(path: "/repos/plume", isRepository: true)
        disk.projects["/docs/notes"] = HomeProject(path: "/docs/notes", isRepository: false)
        let model = model()
        await model.refresh(inputs(paths: ["/repos/plume"]), recentTaskID: nil)

        await model.addFolder("/docs/notes")
        #expect(model.catalog.projects.map(\.path) == ["/docs/notes", "/repos/plume"])
        #expect(model.destination.projectPath == "/docs/notes")
    }

    // MARK: Subfolder

    private func plumeModel() async -> HomeComposerModel {
        disk.projects["/repos/plume"] = HomeProject(path: "/repos/plume", isRepository: true)
        let model = model()
        await model.refresh(inputs(paths: ["/repos/plume"]), recentTaskID: nil)
        return model
    }

    /// Where the plan's task runs once its checkout is known, with every
    /// subfolder treated as present.
    private func workingDirectory(_ model: HomeComposerModel, checkout: String) throws -> String {
        let message = ComposerHandOff.Message(typedText: "Fix it", blocks: [.text("Fix it")])
        let plan = try #require(
            model.catalog.plan(for: model.destination, sending: message, choices: nil, branchPrefix: "")
        )
        return plan.workingDirectory(inCheckout: checkout, isDirectory: { _ in true })
    }

    @Test func theProjectRootRunsInTheCheckout() async throws {
        let model = await plumeModel()
        #expect(model.subfolderTitle == ProjectSubfolder.rootTitle)
        let directory = try workingDirectory(model, checkout: "/repos/plume")
        #expect(directory == "/repos/plume")
    }

    @Test func aSubfolderRunsInsideTheProject() async throws {
        let model = await plumeModel()
        model.chooseWorkspace(.projectFolder)
        model.chooseSubfolder("Android")
        #expect(model.subfolderTitle == "Android")
        let directory = try workingDirectory(model, checkout: "/repos/plume")
        #expect(directory == "/repos/plume/Android")
    }

    @Test func aSubfolderRunsInsideTheNewWorktree() async throws {
        let model = await plumeModel()
        model.chooseSubfolder("Android/app")
        model.chooseWorkspace(.newWorktree)
        let worktree = "/repos/plume/.plume/worktrees/fix-it"
        let directory = try workingDirectory(model, checkout: worktree)
        #expect(directory == "\(worktree)/Android/app")
    }

    @Test func aSubfolderMissingFromTheCheckoutFallsBackToItsRoot() async throws {
        let model = await plumeModel()
        model.chooseSubfolder("Android")
        let message = ComposerHandOff.Message(typedText: "Fix it", blocks: [.text("Fix it")])
        let plan = try #require(
            model.catalog.plan(for: model.destination, sending: message, choices: nil, branchPrefix: "")
        )
        #expect(plan.workingDirectory(inCheckout: "/wt/x", isDirectory: { _ in false }) == "/wt/x")
    }

    @Test func choosingAnotherProjectResetsTheSubfolder() async {
        disk.projects["/repos/other"] = HomeProject(path: "/repos/other", isRepository: true)
        let model = await plumeModel()
        await model.addFolder("/repos/other")
        model.chooseProject("/repos/plume")
        model.chooseSubfolder("Android")
        model.chooseProject("/repos/other")
        #expect(model.destination.subfolder == nil)
    }

    @Test func aPlainFolderOffersNoSubfolder() async {
        disk.projects["/docs/notes"] = HomeProject(path: "/docs/notes", isRepository: false)
        let model = model()
        await model.refresh(inputs(paths: ["/docs/notes"]), recentTaskID: nil)
        model.chooseSubfolder("drafts")
        #expect(!model.offersSubfolders)
        #expect(model.destination.subfolder == nil)
    }

    @Test func aFolderAddedThenDeletedLeavesTheList() async {
        disk.projects["/repos/plume"] = HomeProject(path: "/repos/plume", isRepository: true)
        disk.projects["/docs/notes"] = HomeProject(path: "/docs/notes", isRepository: false)
        let model = model()
        let inputs = inputs(paths: ["/repos/plume"])
        await model.refresh(inputs, recentTaskID: nil)
        await model.addFolder("/docs/notes")

        disk.projects["/docs/notes"] = nil
        await model.refresh(inputs, recentTaskID: nil)
        #expect(model.catalog.projects.map(\.path) == ["/repos/plume"])
    }
}
