import AppKit
import Foundation
import IOKit
import IOKit.pwr_mgt
import Observation
import os

/// Reads `IOPMrootDomain`'s clamshell keys.
///
/// `AppleClamshellCausesSleep` is absent on hardware with no lid, which is how
/// a desktop is told apart from a laptop whose lid currently sleeps it.
@MainActor
@Observable
final class IOKitClamshellState: ClamshellStateReading {
    static let shared = IOKitClamshellState()

    private(set) var behavior: ClamshellSleepBehavior = .noClamshell

    @ObservationIgnored private var screenObserver: (any NSObjectProtocol)?

    init() {
        refresh()
        // Attaching or detaching an external display is what flips clamshell
        // mode, so the guidance would otherwise go stale mid-session.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func refresh() {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPMrootDomain")
        )
        guard service != IO_OBJECT_NULL else {
            Log.app.error("Could not open IOPMrootDomain to read clamshell state")
            return
        }
        defer { IOObjectRelease(service) }

        let key = "AppleClamshellCausesSleep" as CFString
        let value = IORegistryEntryCreateCFProperty(service, key, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Bool

        let read: ClamshellSleepBehavior = switch value {
        case .some(true): .sleeps
        case .some(false): .staysAwake
        case nil: .noClamshell
        }
        if behavior != read {
            behavior = read
        }
    }
}
