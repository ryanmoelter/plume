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

    @ObservationIgnored private let cli: AndroidCLI
    @ObservationIgnored private var modelsProject: String?
    @ObservationIgnored private var hasLoaded = false

    init(cli: AndroidCLI = .shared) {
        self.cli = cli
    }

    var isSignedIn: Bool {
        if case .signedIn = availability { return true }
        return false
    }

    /// The remembered project when it is still ready, else the first one.
    var selectedProject: String? {
        get {
            let remembered = AppSettings.shared.remoteDeviceProjectID
            return projects.contains { $0 == remembered } ? remembered : projects.first
        }
        set { AppSettings.shared.remoteDeviceProjectID = newValue }
    }

    /// Loads once while signed in; otherwise checks again, since the user may have signed in since.
    func loadIfNeeded() async {
        guard !hasLoaded || !isSignedIn else { return }
        await load(refresh: false)
    }

    func load(refresh: Bool) async {
        hasLoaded = true
        availability = .loading
        guard let path = await cli.locate(refresh: refresh) else {
            cliPath = nil
            availability = .cliMissing
            return
        }
        cliPath = path.path
        do {
            let status = try await cli.run(["auth", "status"])
            guard let account = RemoteDeviceParsers.signedInAccount(status.output) else {
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
        isLoadingModels = true
        defer { isLoadingModels = false }
        do {
            let result = try await cli.run(["device", "remote", "models", "--project=\(project)"])
            guard result.succeeded else {
                modelsError = result.failureMessage
                return
            }
            modelsError = nil
            models = RemoteDeviceParsers.models(result.stdout)
            modelsProject = project
        } catch {
            modelsError = error.localizedDescription
        }
    }

    func signOut() async {
        _ = try? await cli.run(["auth", "logout"])
        await load(refresh: false)
    }

    /// `auth login` may open a browser and wait on the terminal, so it runs in Terminal.app.
    func signInInTerminal() {
        guard let cliPath else { return }
        TerminalCommandScript.open(
            prefix: "plume-android-login",
            command: "\(HomebrewUpgrade.shellQuoted(cliPath)) auth login"
        )
    }
}

/// Runs a command in Terminal.app through a temporary `.command` script that deletes itself.
enum TerminalCommandScript {
    private static let terminalBundleID = "com.apple.Terminal"

    static func script(command: String) -> String {
        """
        #!/bin/sh
        rm -f "$0"
        \(command)

        """
    }

    static func open(prefix: String, command: String) {
        do {
            let scriptURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString).command")
            try script(command: command).write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
            guard let terminalURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: terminalBundleID) else {
                Log.app.error("Terminal.app wasn't found")
                return
            }
            NSWorkspace.shared.open([scriptURL], withApplicationAt: terminalURL, configuration: NSWorkspace.OpenConfiguration())
        } catch {
            Log.app.error("Couldn't open Terminal: \(error.localizedDescription, privacy: .public)")
        }
    }
}
