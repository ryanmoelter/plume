import Foundation

/// Decides whether this process may register, re-register or talk to the
/// sleep helper. launchd has one job for every Plume install, so a Debug
/// build that registers repoints it at DerivedData, and a rebuild then
/// breaks the installed app's helper.
nonisolated enum SleepHelperRegistrationGate {
    static let debugOptInKey = "PlumeRegisterSleepHelperInDebug"

    static let disabledReason =
        "The sleep helper is off in Debug builds. Set the PlumeRegisterSleepHelperInDebug default to enable it."

    static func allowsRegistration(isDebugBuild: Bool, isTestHost: Bool, debugOptIn: Bool) -> Bool {
        if isTestHost { return false }
        return isDebugBuild ? debugOptIn : true
    }

    static var allowsRegistrationInThisProcess: Bool {
        #if DEBUG
        let isDebugBuild = true
        #else
        let isDebugBuild = false
        #endif
        return allowsRegistration(
            isDebugBuild: isDebugBuild,
            isTestHost: ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
                || NSClassFromString("XCTestCase") != nil,
            debugOptIn: UserDefaults.standard.bool(forKey: debugOptInKey)
        )
    }
}
