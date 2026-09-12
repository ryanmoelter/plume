import Foundation
import IOKit.pwr_mgt
import os

/// Holds at most one IOKit power assertion, recreating it when the request
/// changes and releasing it when there is nothing to hold.
///
/// An assertion is a suggestion: the OS may still sleep the Mac under battery,
/// thermal, or user pressure, and none of these types survive a lid close.
/// `held` therefore says what Plume asked for, never what the OS will honor.
@MainActor
final class IOKitSleepAssertion: SleepAssertion {
    private(set) var held: SleepAssertionRequest?
    private var id = IOPMAssertionID(0)

    func apply(_ request: SleepAssertionRequest?) {
        // Status events arrive far faster than the reason set actually
        // changes, so an unchanged request must not churn the assertion.
        guard request != held else { return }
        release()
        guard let request else { return }

        var created = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            request.type.assertionName,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            request.reason as CFString,
            &created
        )
        guard result == kIOReturnSuccess else {
            Log.app.error("Could not hold a sleep assertion: \(result, privacy: .public)")
            return
        }
        id = created
        held = request
    }

    private func release() {
        guard held != nil else { return }
        let result = IOPMAssertionRelease(id)
        if result != kIOReturnSuccess {
            Log.app.error("Could not release the sleep assertion: \(result, privacy: .public)")
        }
        id = IOPMAssertionID(0)
        held = nil
    }

    // No `deinit` release: the singleton never deinits, a MainActor `deinit`
    // cannot touch isolated state, and the kernel reaps a dead process's
    // assertions anyway.
}

private extension SleepAssertionType {
    /// The non-alias spelling, which the IOKit headers say to prefer.
    var assertionName: CFString {
        switch self {
        case .preventIdleSystemSleep: kIOPMAssertPreventUserIdleSystemSleep as CFString
        case .networkClientActive: kIOPMAssertNetworkClientActive as CFString
        }
    }
}
