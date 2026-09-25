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
///
/// Plume schedules its own background checks with
/// `checkForUpdateInformation()` rather than letting Sparkle schedule them.
/// Sparkle's scheduled check opens a session that holds the first update it
/// found until relaunch, so a newer release would never replace it in the
/// row; an information check holds no session and reports afresh each time.
@MainActor
@Observable
final class UpdateController: NSObject {
    static let shared = UpdateController()

    private static let feedURLOverrideKey = "PlumeUpdateFeedURLOverride"
    private static let lastUpdateCheckDateKey = "PlumeLastUpdateCheckDate"
    static let homebrewUpgradeCommand = "brew upgrade --cask ryanmoelter/tap/plume"

    static let checkInterval: TimeInterval = 3 * 60 * 60
    /// How often the timer asks whether a check is due. Much shorter than
    /// `checkInterval` so a Mac that slept through the due time checks soon
    /// after waking.
    private static let dueCheckInterval: TimeInterval = 15 * 60

    /// Detected once at launch: the Homebrew prefix whose Caskroom holds
    /// Plume, if any. `installSource` prefers an explicit `AppSettings`
    /// override over this.
    let homebrewPrefix: URL?
    var isHomebrewInstall: Bool { homebrewPrefix != nil }

    private var controller: SPUStandardUpdaterController!
    @ObservationIgnored private var cancellables: Set<AnyCancellable> = []
    @ObservationIgnored private var checkTimer: Timer?

    /// Set before a user-initiated Homebrew check with no update already
    /// known, so the completing callback knows to surface a result instead
    /// of staying silent like a background check.
    private var pendingUserBrewCheck = false

    private(set) var isRunning = false
    var availableUpdate: AvailableUpdate?
    private(set) var canCheckForUpdates = false
    private(set) var lastUpdateCheckDate: Date? {
        didSet { UserDefaults.standard.set(lastUpdateCheckDate, forKey: Self.lastUpdateCheckDateKey) }
    }

    var automaticallyChecksForUpdates: Bool {
        get { AppSettings.shared.automaticallyChecksForUpdates }
        set {
            AppSettings.shared.automaticallyChecksForUpdates = newValue
            checkIfDue()
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
        homebrewPrefix = HomebrewCaskDetector.caskPrefix()
        lastUpdateCheckDate = UserDefaults.standard.object(forKey: Self.lastUpdateCheckDateKey) as? Date
        super.init()

        controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
        observeCanCheckForUpdates()
    }

    private func observeCanCheckForUpdates() {
        canCheckForUpdates = controller.updater.canCheckForUpdates
        controller.updater
            .publisher(for: \.canCheckForUpdates)
            .sink { [weak self] in self?.canCheckForUpdates = $0 }
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
        // Sparkle persists this in user defaults, which outrank the
        // Info.plist value, so the plist alone can't keep it off.
        controller.updater.automaticallyChecksForUpdates = false
        do {
            try controller.updater.start()
            isRunning = true
        } catch {
            // `SPUStandardUpdaterController.startUpdater()` would show a
            // modal "Unable to Check For Updates" alert on this failure,
            // which breaks the no-interruption rule at launch — go through
            // `SPUUpdater.start()` directly instead, which only throws.
            Log.app.error("UpdateController failed to start: \(error.localizedDescription, privacy: .public)")
            return
        }
        checkTimer = Timer.scheduledTimer(withTimeInterval: Self.dueCheckInterval, repeats: true) { _ in
            MainActor.assumeIsolated { UpdateController.shared.checkIfDue() }
        }
        checkIfDue()
    }

    private var feedURLOverride: String? {
        guard let value = UserDefaults.standard.string(forKey: Self.feedURLOverrideKey), !value.isEmpty else {
            return nil
        }
        return value
    }

    static func isCheckDue(lastCheck: Date?, now: Date) -> Bool {
        guard let lastCheck else { return true }
        // A last check in the future means the clock moved back.
        return now < lastCheck || now.timeIntervalSince(lastCheck) >= checkInterval
    }

    private func checkIfDue() {
        guard automaticallyChecksForUpdates, Self.isCheckDue(lastCheck: lastUpdateCheckDate, now: .now) else { return }
        checkInBackground()
    }

    /// A silent check: it updates the sidebar row and nothing else.
    private func checkInBackground() {
        // While a session is open — Sparkle's window, say —
        // checkForUpdateInformation() does nothing and never calls back.
        guard isRunning, canCheckForUpdates else { return }
        controller.updater.checkForUpdateInformation()
    }

    /// Opens details on an already-known update, for the sidebar row (which
    /// only shows while `availableUpdate` is set). A Plume-managed install
    /// opens Sparkle's own window; a Homebrew install opens `UpdatePanelWindow`.
    func showAvailableUpdate() {
        switch installSource {
        case .plume:
            controller.updater.checkForUpdates()
        case .homebrew:
            if let availableUpdate {
                showHomebrewWindow(update: availableUpdate)
            }
        }
    }

    /// Refreshes behind the window, since the update it shows may be hours
    /// old. The window follows `availableUpdate`, so a newer release
    /// replaces it in place.
    private func showHomebrewWindow(update: AvailableUpdate) {
        UpdatePanelWindow.show(update: update)
        checkInBackground()
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
                showHomebrewWindow(update: availableUpdate)
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

    private func presentCheckFailedAlert(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Can't check for updates right now"
        alert.informativeText = error.localizedDescription
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

#if DEBUG
/// Backs the "Updates (Debug)" Settings section (`UpdatesDebugSection`), so
/// both update paths — the installer swap and the background check — are
/// exercisable without reinstalling.
extension UpdateController {
    /// The raw `PlumeUpdateFeedURLOverride` user default. Empty when unset.
    var debugFeedURLOverride: String {
        feedURLOverride ?? ""
    }

    /// Saves a feed URL override typed into the debug text field, and starts
    /// the updater if a non-empty value was just saved and it wasn't already
    /// running — `start()` at launch already ran and found no override to
    /// act on. Sparkle has no API to stop a running updater, so clearing the
    /// override while already running only takes effect on relaunch.
    func debugApplyFeedURLOverride(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.feedURLOverrideKey)
        } else {
            UserDefaults.standard.set(trimmed, forKey: Self.feedURLOverrideKey)
        }
        if !trimmed.isEmpty, !isRunning {
            start()
        }
    }

    /// Runs the scheduled check now, ignoring whether it's due.
    func debugCheckForUpdatesInBackground() {
        checkInBackground()
    }

    /// Clears Sparkle's skipped-version state and the last-check date, plus
    /// Plume's own record of a found update, so the next check behaves like
    /// the very first one.
    func debugResetUpdateState() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "SUSkippedVersion")
        defaults.removeObject(forKey: "SUSkippedMajorVersion")
        defaults.removeObject(forKey: "SUSkippedMajorSubreleaseVersion")
        defaults.removeObject(forKey: "SULastCheckTime")
        lastUpdateCheckDate = nil
        availableUpdate = nil
    }
}
#endif

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
        let foundNoUpdate = (error as NSError?)?.code == Int(SUError.noUpdateError.rawValue)
        if error == nil || foundNoUpdate {
            lastUpdateCheckDate = .now
        }
        // A safety net for a check that failed outright (e.g. no network):
        // neither `didFindValidUpdate` nor `updaterDidNotFindUpdate` fires to
        // clear the flag in that case.
        if pendingUserBrewCheck, installSource == .homebrew, let error, !foundNoUpdate {
            presentCheckFailedAlert(error)
        }
        pendingUserBrewCheck = false
    }
}

/// An update Sparkle found, trimmed to what the sidebar row and
/// `UpdatePanel` need.
struct AvailableUpdate: Equatable {
    let displayVersion: String
    let fullReleaseNotesURL: URL?
    let releaseNotes: String?
    let releaseNotesFormat: ReleaseNotesFormat

    init(item: SUAppcastItem) {
        displayVersion = item.displayVersionString
        fullReleaseNotesURL = item.fullReleaseNotesURL
        releaseNotes = item.itemDescription
        releaseNotesFormat = ReleaseNotesFormat(sparkleFormat: item.itemDescriptionFormat)
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
        caskPrefix(prefixes: prefixes, fileManager: fileManager) != nil
    }

    static func caskPrefix(prefixes: [URL] = defaultPrefixes, fileManager: FileManager = .default) -> URL? {
        prefixes.first { prefix in
            var isDirectory: ObjCBool = false
            let path = prefix.appendingPathComponent("Caskroom/plume").path
            return fileManager.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
    }
}
