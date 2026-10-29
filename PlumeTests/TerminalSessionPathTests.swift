import GhosttyTerminal
import Testing
@testable import Plume

struct TerminalSessionPathTests {
    @Test func pinsThisProcessPathWhenTheCallerSetsNone() {
        let options = TerminalSurfaceOptions(envVars: ["PLUME": "1"])
        let pinned = TerminalSession.pinningPath(options, environment: ["PATH": "/usr/bin:/bin"])
        #expect(pinned.envVars == ["PLUME": "1", "PATH": "/usr/bin:/bin"])
    }

    @Test func keepsThePathTheCallerSet() {
        let options = TerminalSurfaceOptions(envVars: ["PATH": "/opt/bin"])
        let pinned = TerminalSession.pinningPath(options, environment: ["PATH": "/usr/bin:/bin"])
        #expect(pinned.envVars == ["PATH": "/opt/bin"])
    }

    @Test func leavesOptionsAloneWithoutAProcessPath() {
        let options = TerminalSurfaceOptions(envVars: ["PLUME": "1"])
        #expect(TerminalSession.pinningPath(options, environment: [:]).envVars == ["PLUME": "1"])
    }

    @Test func dropsEveryAppBundlesExecutableDirectory() {
        let path = "/Applications/Ghostty.app/Contents/MacOS:/usr/bin:/Users/me/Plume.app/Contents/MacOS/:/bin:/opt/MacOS"
        let pinned = TerminalSession.pinningPath(TerminalSurfaceOptions(), environment: ["PATH": path])
        #expect(pinned.envVars["PATH"] == "/usr/bin:/bin:/opt/MacOS")
    }
}
