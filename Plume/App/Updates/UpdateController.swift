import AppKit
import Combine
import os
import Sparkle

/// Wires Sparkle into Plume.
///
/// Product rule: an available update must never interrupt. No dialog at
/// launch, no system notification, nothing modal, nothing that has to be
/// dismissed. It only ever shows as a row in the sidebar footer, and the
/// user opens Sparkle's install window only when they choose to.
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

    private static let checkInterval: TimeInterval = 60 * 60

    private var controller: SPUStandardUpdaterController!
    @ObservationIgnored private var cancellables: Set<AnyCancellable> = []
    @ObservationIgnored private var checkTimer: Timer?

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
            checkAutomatically()
        }
    }

    private override init() {
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
        // A timer never wakes a sleeping Mac; one that came due during sleep
        // fires once on wake.
        let timer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { _ in
            MainActor.assumeIsolated { UpdateController.shared.checkAutomatically() }
        }
        timer.tolerance = 5 * 60
        checkTimer = timer
        checkAutomatically()
    }

    private var feedURLOverride: String? {
        guard let value = UserDefaults.standard.string(forKey: Self.feedURLOverrideKey), !value.isEmpty else {
            return nil
        }
        return value
    }

    private func checkAutomatically() {
        guard automaticallyChecksForUpdates else { return }
        checkInBackground()
    }

    /// A silent check: it updates the sidebar row and nothing else.
    private func checkInBackground() {
        // While a session is open — Sparkle's window, say —
        // checkForUpdateInformation() does nothing and never calls back.
        guard isRunning, canCheckForUpdates else { return }
        controller.updater.checkForUpdateInformation()
    }

    /// Opens Sparkle's window on an already-known update, for the sidebar
    /// row (which only shows while `availableUpdate` is set).
    func showAvailableUpdate() {
        controller.updater.checkForUpdates()
    }

    /// A user-initiated check, from the menu or Settings. Sparkle's window
    /// reports the result, which is no interruption since the user asked.
    func checkForUpdates() {
        guard isRunning else {
            #if DEBUG
            presentUpdatesOffAlert()
            #endif
            return
        }
        controller.updater.checkForUpdates()
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
        availableUpdate = AvailableUpdate(item: item)
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        availableUpdate = nil
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
    }
}

/// An update Sparkle found, trimmed to what the sidebar row needs.
struct AvailableUpdate: Equatable {
    let displayVersion: String

    init(item: SUAppcastItem) {
        displayVersion = item.displayVersionString
    }
}
