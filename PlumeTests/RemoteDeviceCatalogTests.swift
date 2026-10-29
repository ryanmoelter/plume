import Foundation
import Testing

@testable import Plume

/// The device picker's model list always belongs to the chosen project: switching projects or
/// signing out empties it, and a load for a project no longer chosen never lands.
@MainActor
struct RemoteDeviceCatalogTests {
    private let cli = GatedModelsCLI()
    private let settings = AppSettings(defaults: UserDefaults(suiteName: "RemoteDeviceCatalogTests-\(UUID().uuidString)")!)

    private func signedInCatalog() async -> RemoteDeviceCatalog {
        let catalog = RemoteDeviceCatalog(cli: cli, settings: settings) { _ in URL(fileURLWithPath: "/usr/local/bin/android") }
        await catalog.load(refresh: false)
        return catalog
    }

    @Test func switchingProjectsClearsTheModels() async {
        cli.open("p")
        let catalog = await signedInCatalog()
        await catalog.loadModels()
        #expect(catalog.models.map(\.id) == ["p/31"])

        catalog.selectedProject = "q"

        #expect(catalog.models.isEmpty)
        #expect(!catalog.isLoadingModels)
    }

    @Test func aLoadForAProjectNoLongerChosenIsDropped() async {
        let catalog = await signedInCatalog()
        let staleLoad = Task { await catalog.loadModels() }
        await waitUntilSoon { cli.started.contains("p") }

        catalog.selectedProject = "q"
        cli.open("q")
        await catalog.loadModels()
        cli.open("p")
        await staleLoad.value

        #expect(catalog.models.map(\.id) == ["q/31"])
        #expect(catalog.selectedProject == "q")
    }

    @Test func overlappingLoadsForOneProjectRunModelsOnce() async {
        let catalog = await signedInCatalog()
        let first = Task { await catalog.loadModels() }
        await waitUntilSoon { cli.started.contains("p") }

        await catalog.loadModels()
        cli.open("p")
        await first.value

        #expect(cli.started == ["p"])
        #expect(catalog.models.map(\.id) == ["p/31"])
    }

    @Test func aLoadWhoseCallerIsCancelledStillPublishesItsModels() async {
        let catalog = await signedInCatalog()
        let abandoned = Task { await catalog.loadModels() }
        await waitUntilSoon { cli.started.contains("p") }

        abandoned.cancel()
        await catalog.loadModels()
        cli.open("p")
        await abandoned.value

        #expect(catalog.modelsError == nil)
        #expect(catalog.models.map(\.id) == ["p/31"])
        #expect(!catalog.isLoadingModels)
    }

    @Test func signingOutClearsTheModels() async {
        cli.open("p")
        let catalog = await signedInCatalog()
        await catalog.loadModels()

        cli.signedIn.value = false
        await catalog.signOut()

        #expect(catalog.availability == .signedOut)
        #expect(catalog.models.isEmpty)
    }

    @Test func aFailedProjectListKeepsTheAccountAndClearsProjects() async {
        let catalog = await signedInCatalog()
        #expect(catalog.projects == ["p", "q"])

        cli.projectsFail.value = true
        await catalog.load(refresh: true)

        #expect(catalog.availability == .projectsFailed(account: "Ryan <r@example.com>", message: "Error: HTTP connect timed out"))
        #expect(catalog.projects.isEmpty)
    }

    @Test func aMissingToolIsLookedForAgain() async {
        let found = LockedValue<URL?>(nil)
        let lookups = LockedValue(0)
        let tool = AndroidCLI {
            lookups.value += 1
            return found.value
        }

        #expect(await tool.locate() == nil)
        found.value = URL(fileURLWithPath: "/usr/local/bin/android")
        #expect(await tool.locate() == found.value)
        #expect(await tool.locate() == found.value)
        #expect(lookups.value == 2)
    }
}

@MainActor
private func waitUntilSoon(_ condition: () -> Bool) async {
    for _ in 0..<400 {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
}

/// Signed in with projects `p` and `q`. A `models` call for a project waits until the test opens it,
/// then answers with one model whose codename is the project.
nonisolated final class GatedModelsCLI: AndroidCLIRunning, @unchecked Sendable {
    let signedIn = LockedValue(true)
    let projectsFail = LockedValue(false)
    private let opened = LockedValue<Set<String>>([])
    private let startedProjects = LockedValue<[String]>([])

    var started: [String] { startedProjects.value }

    func open(_ project: String) {
        opened.value.insert(project)
    }

    func run(_ arguments: [String], timeout: Duration, onOutput: (@Sendable (String) -> Void)?) async throws -> AndroidCLIResult {
        switch arguments.prefix(3) {
        case ["auth", "status"]:
            return AndroidCLIResult(status: 0, stdout: signedIn.value ? "Logged in as Ryan <r@example.com>\n" : "You are not logged in.\n", stderr: "")
        case ["device", "remote", "projects"]:
            if projectsFail.value { return AndroidCLIResult(status: 1, stdout: "", stderr: "Error: HTTP connect timed out\n") }
            return AndroidCLIResult(status: 0, stdout: "Projects ready for streaming:\n  p\n  q\n", stderr: "")
        case ["device", "remote", "models"]:
            let project = String(arguments.last?.dropFirst("--project=".count) ?? "")
            startedProjects.value.append(project)
            while !opened.value.contains(project) { try await Task.sleep(for: .milliseconds(2)) }
            return AndroidCLIResult(status: 0, stdout: "├─ Google [1]\n│  └─ Pixel 6                        \(project)/31\n", stderr: "")
        default:
            return AndroidCLIResult(status: 0, stdout: "", stderr: "")
        }
    }
}
