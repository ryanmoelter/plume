import AppKit
import Combine
import os
import Sparkle

/// Wires Sparkle into Plume.
///
/// Product rule: an available update must never interrupt. No dialog at
/// launch, no system notification, nothing modal, nothing that has to be
/// dismissed. It only ever shows as a row in the sidebar footer, and the
/// user opens details — Sparkle's install window, or the Homebrew panel —
/// only when they choose to.
@MainActor
@Observable
final class UpdateController: NSObject {
    static let shared = UpdateController()

    private static let feedURLOverrideKey = "PlumeUpdateFeedURLOverride"
    static let homebrewUpgradeCommand = "brew upgrade --cask ryanmoelter/tap/plume"

    /// Detected once at launch: whether this bundle lives under a Homebrew
    /// Caskroom. `installSource` prefers an explicit `AppSettings` override
    /// over this.
    let isHomebrewInstall: Bool

    private var controller: SPUStandardUpdaterController!
    @ObservationIgnored private var cancellables: Set<AnyCancellable> = []

    /// Set before a user-initiated Homebrew check with no update already
    /// known, so the completing callback knows to surface a result instead
    /// of staying silent like a background check.
    private var pendingUserBrewCheck = false

    private(set) var isRunning = false
    /// The last update Sparkle found, or nil. In Homebrew mode this is not
    /// re-verified by a later check: Sparkle's own session stays on the
    /// first update it found until the app relaunches, so a newer release
    /// isn't seen until then.
    var availableUpdate: AvailableUpdate?
    private(set) var canCheckForUpdates = false
    private(set) var lastUpdateCheckDate: Date?

    /// Forwards to `SPUUpdater.automaticallyChecksForUpdates`, mirrored into
    /// a stored property so reading it in a view registers as an Observation
    /// dependency.
    var automaticallyChecksForUpdates: Bool {
        didSet {
            controller.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        }
    }

    /// `.plume` unless `AppSettings` overrides it or this bundle was
    /// detected as a Homebrew install.
    var installSource: UpdateInstallSource {
        UpdateInstallSource.resolve(
            override: AppSettings.shared.updateInstallSourceOverride,
            isHomebrewInstall: isHomebrewInstall
        )
    }

    private override init() {
        isHomebrewInstall = HomebrewCaskDetector.isCaskInstall()
        automaticallyChecksForUpdates = true
        super.init()

        controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: self,
            userDriverDelegate: self
        )
        automaticallyChecksForUpdates = controller.updater.automaticallyChecksForUpdates
        observeCanCheckForUpdates()
        observeLastUpdateCheckDate()
    }

    private func observeCanCheckForUpdates() {
        canCheckForUpdates = controller.updater.canCheckForUpdates
        controller.updater
            .publisher(for: \.canCheckForUpdates)
            .sink { [weak self] in self?.canCheckForUpdates = $0 }
            .store(in: &cancellables)
    }

    private func observeLastUpdateCheckDate() {
        lastUpdateCheckDate = controller.updater.lastUpdateCheckDate
        controller.updater
            .publisher(for: \.lastUpdateCheckDate)
            .sink { [weak self] in self?.lastUpdateCheckDate = $0 }
            .store(in: &cancellables)
    }

    /// In DEBUG this only happens when `PlumeUpdateFeedURLOverride` is set —
    /// a debug build must never replace itself with a Release DMG — but
    /// Release always starts it.
    func start() {
        guard !isRunning else { return }
        #if DEBUG
        guard feedURLOverride != nil else { return }
        #endif
        do {
            try controller.updater.start()
            isRunning = true
        } catch {
            // `SPUStandardUpdaterController.startUpdater()` would show a
            // modal "Unable to Check For Updates" alert on this failure,
            // which breaks the no-interruption rule at launch — go through
            // `SPUUpdater.start()` directly instead, which only throws.
            Log.app.error("UpdateController failed to start: \(error.localizedDescription, privacy: .public)")
        }
    }

    private var feedURLOverride: String? {
        guard let value = UserDefaults.standard.string(forKey: Self.feedURLOverrideKey), !value.isEmpty else {
            return nil
        }
        return value
    }

    /// Opens details on an already-known update, for the sidebar row (which
    /// only shows while `availableUpdate` is set). A Plume-managed install
    /// opens Sparkle's own window directly; a Homebrew install has nothing
    /// of its own to open, so this returns `true` and leaves showing the
    /// popover to the caller, which is the one that knows where to anchor it.
    @discardableResult
    func showAvailableUpdate() -> Bool {
        switch installSource {
        case .plume:
            controller.updater.checkForUpdates()
            return false
        case .homebrew:
            return true
        }
    }

    /// A user-initiated check, from the menu or Settings. Unlike a
    /// background check, this may report a result — a standalone window for
    /// a found Homebrew update, or an "up to date" `NSAlert` — since the
    /// user asked, so neither is an interruption.
    func checkForUpdates() {
        guard isRunning else {
            #if DEBUG
            presentUpdatesOffAlert()
            #endif
            return
        }
        switch installSource {
        case .plume:
            controller.updater.checkForUpdates()
        case .homebrew:
            if let availableUpdate {
                UpdatePanelWindow.show(update: availableUpdate)
            } else if canCheckForUpdates {
                pendingUserBrewCheck = true
                controller.updater.checkForUpdateInformation()
            }
            // Else a session is already in progress: checkForUpdateInformation()
            // would no-op with no callback to ever clear the flag, so leave
            // it unset rather than getting stuck pending.
        }
    }

    private func presentUpToDateAlert() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "the current version"
        let alert = NSAlert()
        alert.messageText = "Plume is up to date"
        alert.informativeText = "You have the latest version, \(version)."
        alert.runModal()
    }

    #if DEBUG
    private func presentUpdatesOffAlert() {
        let alert = NSAlert()
        alert.messageText = "Updates are off in this build"
        alert.informativeText = "Set the PlumeUpdateFeedURLOverride user default to test updates in a debug build."
        alert.runModal()
    }
    #endif
}

// MARK: - SPUUpdaterDelegate

extension UpdateController: SPUUpdaterDelegate {
    func feedURLString(for updater: SPUUpdater) -> String? {
        feedURLOverride
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let update = AvailableUpdate(item: item)
        availableUpdate = update
        if pendingUserBrewCheck, installSource == .homebrew {
            UpdatePanelWindow.show(update: update)
        }
        pendingUserBrewCheck = false
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        availableUpdate = nil
        if pendingUserBrewCheck, installSource == .homebrew {
            presentUpToDateAlert()
        }
        pendingUserBrewCheck = false
    }

    func updater(
        _ updater: SPUUpdater,
        userDidMake choice: SPUUserUpdateChoice,
        forUpdate item: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        // `.dismiss` (Remind Me Later) and `.install` both leave the update
        // recorded: dismissing keeps the reminder live, and installing is
        // about to relaunch the app anyway.
        if choice == .skip {
            availableUpdate = nil
        }
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        // A safety net for a check that failed outright (e.g. no network):
        // neither `didFindValidUpdate` nor `updaterDidNotFindUpdate` fires to
        // clear the flag in that case, and `lastUpdateCheckDate` is kept in
        // sync by its own KVO publisher, not here.
        pendingUserBrewCheck = false
    }
}

// MARK: - SPUStandardUserDriverDelegate

extension UpdateController: SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Always `false`: nothing about a scheduled check ever shows Sparkle's
    /// own UI. `didFindValidUpdate` already recorded `availableUpdate`,
    /// which is Plume's own gentle reminder — the sidebar row.
    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        false
    }

    /// Required once the method above can return `false`: Sparkle's header
    /// says the delegate must record the update here when it declines to let
    /// the standard driver show it. `didFindValidUpdate` still does the same
    /// for `checkForUpdateInformation`, which never reaches the user driver.
    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        availableUpdate = AvailableUpdate(item: update)
    }
}

/// An update Sparkle found, trimmed to what the sidebar row and
/// `UpdatePanel` need.
struct AvailableUpdate: Equatable {
    let displayVersion: String
    let releaseNotes: String?
    let releaseNotesFormat: ReleaseNotesFormat
    let fullReleaseNotesURL: URL?

    init(item: SUAppcastItem) {
        displayVersion = item.displayVersionString
        releaseNotes = item.itemDescription
        releaseNotesFormat = ReleaseNotesFormat(sparkleFormat: item.itemDescriptionFormat)
        fullReleaseNotesURL = item.fullReleaseNotesURL
    }
}

/// Sparkle's three release-notes formats (`SUAppcastItem.m`), plus how an
/// absent or unrecognized `sparkle:format` resolves: to `html`, the format
/// from before `plain-text`/`markdown` existed — not to markdown.
enum ReleaseNotesFormat: Equatable {
    case markdown
    case plainText
    case html

    init(sparkleFormat: String?) {
        switch sparkleFormat?.lowercased() {
        case "markdown": self = .markdown
        case "plain-text": self = .plainText
        default: self = .html
        }
    }
}

/// Where an update installs from, for the sidebar row's action and the
/// Settings picker.
enum UpdateInstallSource: String, CaseIterable, Identifiable, Sendable {
    case plume
    case homebrew

    var id: String { rawValue }

    var label: String {
        switch self {
        case .plume: "Plume"
        case .homebrew: "Homebrew"
        }
    }

    /// Pure so it's testable without touching Sparkle: an explicit override
    /// always wins, otherwise it follows detection.
    static func resolve(override: UpdateInstallSource?, isHomebrewInstall: Bool) -> UpdateInstallSource {
        override ?? (isHomebrewInstall ? .homebrew : .plume)
    }
}

/// Whether this app bundle was installed by Homebrew, detected by the
/// Caskroom directory it leaves behind rather than anything Sparkle reports.
enum HomebrewCaskDetector {
    static let defaultPrefixes: [URL] = [
        URL(fileURLWithPath: "/opt/homebrew"),
        URL(fileURLWithPath: "/usr/local"),
    ]

    static func isCaskInstall(prefixes: [URL] = defaultPrefixes, fileManager: FileManager = .default) -> Bool {
        prefixes.contains { prefix in
            var isDirectory: ObjCBool = false
            let path = prefix.appendingPathComponent("Caskroom/plume").path
            return fileManager.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
    }
}
