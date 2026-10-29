import AppKit
import Foundation
import Observation
import os

/// What Device Streaming offers this Mac: whether the `android` tool is installed and signed in,
/// its projects and its models. Shared by the device picker and Settings ▸ Integrations.
@MainActor
@Observable
final class RemoteDeviceCatalog {
    static let shared = RemoteDeviceCatalog()

    enum Availability: Equatable {
        case loading
        case cliMissing
        case signedOut
        case signedIn(account: String)
        case failed(String)
        /// Signed in, but the project list couldn't be read.
        case projectsFailed(account: String, message: String)
    }

    private(set) var availability: Availability = .loading
    private(set) var cliPath: String?
    private(set) var projects: [String] = []
    private(set) var models: [RemoteDeviceModel] = []
    private(set) var isLoadingModels = false
    private(set) var modelsError: String?

    @ObservationIgnored private let cli: AndroidCLIRunning
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let locate: (_ refresh: Bool) async -> URL?
    @ObservationIgnored private var modelsProject: String?
    /// The picker asks both when it appears and when the project resolves, which is one load.
    @ObservationIgnored private var loadingModelsProject: String?
    /// Only the latest `loadModels` may publish, so a slow load for a project no longer chosen
    /// can't overwrite the current one.
    @ObservationIgnored private var modelsLoad = 0
    @ObservationIgnored private var hasLoaded = false
    /// Only the latest `load` may publish, so a slow check can't overwrite a newer one.
    @ObservationIgnored private var loadGeneration = 0
    @ObservationIgnored private var isLoading = false

    init(cli: AndroidCLI = .shared) {
        self.cli = cli
        settings = .shared
        locate = { await cli.locate(refresh: $0) }
    }

    init(cli: AndroidCLIRunning, settings: AppSettings, locate: @escaping (_ refresh: Bool) async -> URL?) {
        self.cli = cli
        self.settings = settings
        self.locate = locate
    }

    var isSignedIn: Bool {
        if case .signedIn = availability { return true }
        return false
    }

    /// The remembered project when it is still ready, else the first one.
    var selectedProject: String? {
        get {
            let remembered = settings.remoteDeviceProjectID
            return projects.contains { $0 == remembered } ? remembered : projects.first
        }
        set {
            guard newValue != selectedProject else { return }
            settings.remoteDeviceProjectID = newValue
            clearModels()
        }
    }

    /// Loads once while signed in; otherwise checks again, since the user may have signed in since.
    func loadIfNeeded() async {
        guard !hasLoaded || !isSignedIn else { return }
        await load(refresh: false)
    }

    func load(refresh: Bool) async {
        guard refresh || !isLoading else { return }
        hasLoaded = true
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        availability = .loading
        defer { if generation == loadGeneration { isLoading = false } }
        guard let path = await locate(refresh), generation == loadGeneration else {
            guard generation == loadGeneration else { return }
            cliPath = nil
            availability = .cliMissing
            return
        }
        cliPath = path.path
        do {
            let status = try await cli.run(["auth", "status"])
            guard generation == loadGeneration else { return }
            guard let account = RemoteDeviceParsers.signedInAccount(status.output) else {
                availability = status.succeeded ? .signedOut : .failed(status.failureMessage)
                projects = []
                return
            }
            let listing = try await cli.run(["device", "remote", "projects"])
            guard generation == loadGeneration else { return }
            guard listing.succeeded else {
                availability = .projectsFailed(account: account, message: listing.failureMessage)
                projects = []
                return
            }
            projects = RemoteDeviceParsers.projects(listing.stdout)
            availability = .signedIn(account: account)
        } catch {
            guard generation == loadGeneration else { return }
            availability = .failed(error.localizedDescription)
            projects = []
        }
    }

    func loadModels(refresh: Bool = false) async {
        guard let project = selectedProject else { return }
        guard refresh || modelsProject != project || models.isEmpty else { return }
        guard refresh || loadingModelsProject != project else { return }
        modelsLoad += 1
        let load = modelsLoad
        isLoadingModels = true
        loadingModelsProject = project
        // Unstructured so the picker disappearing can't cancel it: a later call for this project
        // is turned away while it runs, and would otherwise be left with nothing to show.
        let outcome = await Task { [cli] in
            try await cli.run(["device", "remote", "models", "--project=\(project)"])
        }.result
        guard load == modelsLoad else { return }
        isLoadingModels = false
        loadingModelsProject = nil
        guard project == selectedProject else { return }
        switch outcome {
        case .success(let result) where result.succeeded:
            modelsError = nil
            models = RemoteDeviceParsers.models(result.stdout)
            modelsProject = project
        case .success(let result):
            modelsError = result.failureMessage
        case .failure(let error):
            modelsError = error.localizedDescription
        }
    }

    func signOut() async {
        _ = try? await cli.run(["auth", "logout"])
        clearModels()
        await load(refresh: false)
    }

    private func clearModels() {
        modelsLoad += 1
        models = []
        modelsProject = nil
        modelsError = nil
        isLoadingModels = false
        loadingModelsProject = nil
    }

    /// `auth login` may open a browser and wait on the terminal, so it runs in a terminal task.
    /// The account is checked again once it exits.
    func signIn() {
        guard let cliPath else { return }
        guard let session = CLICommandHandler.shared.openCommandTask(
            title: "Sign in to Device Streaming",
            command: "\(shellQuoted(cliPath)) auth login"
        ) else {
            Log.app.error("Couldn't sign in to Device Streaming: no Plume window is open")
            return
        }
        reloadWhenExited(session)
    }

    private func reloadWhenExited(_ session: TerminalSession) {
        withObservationTracking {
            _ = session.hasExited
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if session.hasExited {
                    await load(refresh: true)
                } else {
                    reloadWhenExited(session)
                }
            }
        }
    }
}
