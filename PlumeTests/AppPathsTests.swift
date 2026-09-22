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

    @Test func controlSocketHonorsTheOverride() {
        let path = AppPaths.controlSocketPath(pid: 42, environment: ["PLUME_CONTROL_SOCKET": "/tmp/x.sock"])
        #expect(path == "/tmp/x.sock")
    }

    @Test func controlSocketLivesUnderTheControlDirectory() {
        let path = AppPaths.controlSocketPath(pid: 42, environment: [:])
        #expect(path.hasPrefix(AppPaths.controlDirectory.path(percentEncoded: false)))
        #expect(path.hasSuffix("/42.sock"))
    }

    /// A Unix socket path is capped at 103 bytes, and the preferred path is
    /// under Application Support, so a long enough HOME must fall back to /tmp.
    @Test func controlSocketFallsBackToTmpWhenThePathWouldNotFit() {
        let preferred = AppPaths.controlSocket(pid: 42).path(percentEncoded: false)
        guard preferred.utf8.count > AppPaths.maxSocketPathLength else {
            #expect(AppPaths.controlSocketPath(pid: 42, environment: [:]) == preferred)
            return
        }
        #expect(AppPaths.controlSocketPath(pid: 42, environment: [:]) == "/tmp/plume-control-42.sock")
    }
}
