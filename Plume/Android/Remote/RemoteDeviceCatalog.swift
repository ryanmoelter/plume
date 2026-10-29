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
    /// Only the latest `loadModels` may publish, so a slow load for a project no longer chosen
    /// can't overwrite the current one.
    @ObservationIgnored private var modelsLoad = 0
    @ObservationIgnored private var hasLoaded = false

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
        hasLoaded = true
        availability = .loading
        guard let path = await locate(refresh) else {
            cliPath = nil
            availability = .cliMissing
            return
        }
        cliPath = path.path
        do {
            let status = try await cli.run(["auth", "status"])
            guard let account = RemoteDeviceParsers.signedInAccount(status.output) else {
                guard status.succeeded else {
                    availability = .failed(status.failureMessage)
                    projects = []
                    return
                }
                availability = .signedOut
                projects = []
                return
            }
            let listing = try await cli.run(["device", "remote", "projects"])
            guard listing.succeeded else {
                availability = .failed(listing.failureMessage)
                return
            }
            projects = RemoteDeviceParsers.projects(listing.stdout)
            availability = .signedIn(account: account)
        } catch {
            availability = .failed(error.localizedDescription)
        }
    }

    func loadModels(refresh: Bool = false) async {
        guard let project = selectedProject else { return }
        guard refresh || modelsProject != project || models.isEmpty else { return }
        modelsLoad += 1
        let load = modelsLoad
        isLoadingModels = true
        let outcome: Result<AndroidCLIResult, Error>
        do {
            outcome = .success(try await cli.run(["device", "remote", "models", "--project=\(project)"]))
        } catch {
            outcome = .failure(error)
        }
        guard load == modelsLoad else { return }
        isLoadingModels = false
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
    }

    /// `auth login` may open a browser and wait on the terminal, so it runs in Terminal.app.
    func signInInTerminal() {
        guard let cliPath else { return }
        TerminalCommandScript.open(
            prefix: "plume-android-login",
            command: "\(TerminalCommandScript.shellQuoted(cliPath)) auth login"
        ) { message in
            Log.app.error("Couldn't open Terminal: \(message, privacy: .public)")
        }
    }
}
