import Foundation
import Observation

/// The seam over `ProcessInfo.thermalState`, so the coordinator is testable
/// without depending on the real thermal pressure of the machine running the
/// test.
@MainActor
protocol ThermalStateSource: AnyObject {
    var state: ProcessInfo.ThermalState { get }
}

/// Tracks `ProcessInfo.thermalState`, updating on
/// `thermalStateDidChangeNotification`.
@MainActor
@Observable
final class ThermalStateMonitor: ThermalStateSource {
    private(set) var state: ProcessInfo.ThermalState

    @ObservationIgnored private var observer: NSObjectProtocol?

    init() {
        state = ProcessInfo.processInfo.thermalState
        observer = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.state = ProcessInfo.processInfo.thermalState
            }
        }
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}
