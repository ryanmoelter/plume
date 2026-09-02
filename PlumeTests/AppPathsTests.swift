import Foundation
import Testing

@testable import Plume

/// The debug build gets its own Application Support directory, so a debug run
/// never writes the data the installed app reads.
struct AppPathsTests {
    @Test func debugBundleGetsItsOwnDirectory() {
        #expect(AppPaths.directoryName(forBundleID: "com.ryanmoelter.Plume.debug") == "Plume.debug")
    }

    @Test func releaseBundleUsesThePlainDirectory() {
        #expect(AppPaths.directoryName(forBundleID: "com.ryanmoelter.Plume") == "Plume")
    }

    /// The test host has no app bundle ID, and must not land on the debug path.
    @Test func anAbsentBundleIDUsesThePlainDirectory() {
        #expect(AppPaths.directoryName(forBundleID: nil) == "Plume")
    }

    @Test func eventsAndHooksLiveUnderTheSameDirectory() {
        let support = AppPaths.applicationSupport.path
        #expect(AppPaths.storeFile.path.hasPrefix(support))
        #expect(AppPaths.hookSettingsFile.path.hasPrefix(support))
        #expect(AppPaths.eventsDirectory.path.hasPrefix(support))
    }

}
