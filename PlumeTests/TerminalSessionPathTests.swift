import Foundation
import GhosttyTerminal
import Testing
@testable import Plume

struct TerminalSessionPathTests {
    private let helpers = URL(fileURLWithPath: "/Users/me/Plume.app/Contents/Helpers")

    @Test func pinsThisProcessPathWhenTheCallerSetsNone() {
        let options = TerminalSurfaceOptions(envVars: ["PLUME": "1"])
        let pinned = TerminalSession.pinningPath(options, environment: ["PATH": "/usr/bin:/bin"], helpersDirectory: nil)
        #expect(pinned.envVars == ["PLUME": "1", "PATH": "/usr/bin:/bin"])
    }

    @Test func keepsThePathTheCallerSet() {
        let options = TerminalSurfaceOptions(envVars: ["PATH": "/opt/bin"])
        let pinned = TerminalSession.pinningPath(options, environment: ["PATH": "/usr/bin:/bin"], helpersDirectory: helpers)
        #expect(pinned.envVars == ["PATH": "/opt/bin"])
    }

    @Test func leavesOptionsAloneWithoutAProcessPath() {
        let options = TerminalSurfaceOptions(envVars: ["PLUME": "1"])
        #expect(TerminalSession.pinningPath(options, environment: [:], helpersDirectory: helpers).envVars == ["PLUME": "1"])
    }

    @Test func dropsEveryAppBundlesExecutableDirectory() {
        let path = "/Applications/Ghostty.app/Contents/MacOS:/usr/bin:/Users/me/Plume.app/Contents/MacOS/:/bin:/opt/MacOS"
        let pinned = TerminalSession.pinningPath(TerminalSurfaceOptions(), environment: ["PATH": path], helpersDirectory: nil)
        #expect(pinned.envVars["PATH"] == "/usr/bin:/bin:/opt/MacOS")
    }

    @Test func appendsTheHelpersDirectoryOnceAfterDroppingMacOS() {
        let path = "/Users/me/Plume.app/Contents/MacOS:/usr/bin:/bin"
        let pinned = TerminalSession.pinningPath(TerminalSurfaceOptions(), environment: ["PATH": path], helpersDirectory: helpers)
        #expect(pinned.envVars["PATH"] == "/usr/bin:/bin:/Users/me/Plume.app/Contents/Helpers")
    }

    @Test func doesNotAppendAHelpersDirectoryTheProcessPathAlreadyHas() {
        let path = "/usr/bin:/Users/me/Plume.app/Contents/Helpers"
        let pinned = TerminalSession.pinningPath(TerminalSurfaceOptions(), environment: ["PATH": path], helpersDirectory: helpers)
        #expect(pinned.envVars["PATH"] == path)
    }

    @Test func dropsAnotherAppsHelpersDirectoryButKeepsPlainOnes() {
        let path = "/Applications/Plume.app/Contents/Helpers:/usr/bin:/opt/Helpers:/Users/me/Other.app/Contents/Helpers/"
        let pinned = TerminalSession.pinningPath(TerminalSurfaceOptions(), environment: ["PATH": path], helpersDirectory: helpers)
        #expect(pinned.envVars["PATH"] == "/usr/bin:/opt/Helpers:/Users/me/Plume.app/Contents/Helpers")
    }
}
