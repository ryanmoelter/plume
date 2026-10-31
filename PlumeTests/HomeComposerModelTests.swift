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
