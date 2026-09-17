import Foundation

// Compiled into both the app and the PlumeSleepHelper tool. The helper gets it
// through an explicit build-file reference in project.pbxproj, since the
// synchronized group only covers the app target.

/// The Mach service the privileged helper listens on, and its launchd label.
nonisolated let sleepHelperServiceName = "com.ryanmoelter.Plume.SleepHelper"

/// The launchd plist inside `Contents/Library/LaunchDaemons`.
nonisolated let sleepHelperPlistName = "com.ryanmoelter.Plume.SleepHelper.plist"

/// How often the app renews its lease while the override is engaged. The
/// helper clears the override after three missed renewals, so a wedged app
/// cannot leave the Mac unable to sleep.
nonisolated let sleepHelperHeartbeatInterval: TimeInterval = 30
nonisolated let sleepHelperLeaseTimeout: TimeInterval = 90

/// What the root helper does on Plume's behalf: flip `SleepDisabled` on
/// `IOPMrootDomain`, the one setting powerd consults on a lid close.
///
/// Every reply carries the value actually in the registry afterwards, so the
/// app never has to trust its own bookkeeping about root-owned state.
@objc protocol SleepHelperProtocol {
    func setSleepDisabled(_ disabled: Bool, reply: @escaping (Bool, String?) -> Void)
    func currentState(reply: @escaping (Bool) -> Void)
    func heartbeat(reply: @escaping (Bool) -> Void)
}
