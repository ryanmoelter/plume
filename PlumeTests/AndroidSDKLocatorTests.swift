import Foundation
import Testing
@testable import Plume

struct AndroidSDKLocatorTests {
    @Test func firstExecutableCandidateWins() {
        let result = AndroidSDKLocator.resolve(
            candidates: ["/a", "/b", "/c"],
            isExecutable: { $0 == "/b/emulator/emulator" || $0 == "/b/platform-tools/adb" || $0 == "/c/emulator/emulator" }
        )
        #expect(result.root == "/b")
        #expect(result.adbRoot == "/b")
        #expect(result.searched == ["/a", "/b"])
    }

    @Test func anEmulatorSDKWithoutAdbTakesAdbFromAnotherCandidate() {
        let later = AndroidSDKLocator.resolve(
            candidates: ["/sdk", "/a", "/tools", "/b"],
            isExecutable: { $0 == "/sdk/emulator/emulator" || $0 == "/tools/platform-tools/adb" || $0 == "/b/platform-tools/adb" }
        )
        #expect(later.root == "/sdk")
        #expect(later.adbRoot == "/tools")
        #expect(later.searched == ["/sdk", "/a", "/tools"])

        let earlier = AndroidSDKLocator.resolve(
            candidates: ["/tools", "/sdk"],
            isExecutable: { $0 == "/tools/platform-tools/adb" || $0 == "/sdk/emulator/emulator" }
        )
        #expect(earlier.root == "/sdk")
        #expect(earlier.adbRoot == "/tools")
    }

    @Test func anEmulatorSDKPrefersItsOwnAdb() {
        let result = AndroidSDKLocator.resolve(
            candidates: ["/tools", "/sdk"],
            isExecutable: { $0 == "/tools/platform-tools/adb" || $0 == "/sdk/emulator/emulator" || $0 == "/sdk/platform-tools/adb" }
        )
        #expect(result.root == "/sdk")
        #expect(result.adbRoot == "/sdk")
    }

    @Test func adbOnlyInstallIsFoundWhenNoCandidateHasAnEmulator() {
        let result = AndroidSDKLocator.resolve(
            candidates: ["/a", "/tools", "/b"],
            isExecutable: { $0 == "/tools/platform-tools/adb" || $0 == "/b/platform-tools/adb" }
        )
        #expect(result.root == "/tools")
        #expect(result.adbRoot == "/tools")
        #expect(result.searched == ["/a", "/tools", "/b"])
    }

    @Test func emulatorInstallBeatsAnEarlierAdbOnlyOne() {
        let result = AndroidSDKLocator.resolve(
            candidates: ["/tools", "/sdk"],
            isExecutable: { $0 == "/tools/platform-tools/adb" || $0 == "/sdk/emulator/emulator" }
        )
        #expect(result.root == "/sdk")
    }

    @Test func invalidCandidatesAreSkipped() {
        let result = AndroidSDKLocator.resolve(candidates: ["", "/a"], isExecutable: { _ in false })
        #expect(result.root == nil)
        #expect(result.searched == ["/a"])
    }

    @Test func duplicatesAreSearchedOnce() {
        let result = AndroidSDKLocator.resolve(candidates: ["/a", "/a", "~/sdk"], isExecutable: { _ in false }, home: "/home/me")
        #expect(result.searched == ["/a", "/home/me/sdk"])
    }

    @Test func expandsTilde() {
        #expect(AndroidSDKLocator.expandTilde("~/Library/Android/sdk", home: "/h") == "/h/Library/Android/sdk")
        #expect(AndroidSDKLocator.expandTilde("~", home: "/h") == "/h")
        #expect(AndroidSDKLocator.expandTilde("/x/~y", home: "/h") == "/x/~y")
    }

    @Test func parsesNoisyShellOutput() {
        let output = """
        zsh: no such key
        Last login: today
        \(AndroidSDKLocator.beginMarker)
        ANDROID_HOME=/opt/sdk
        ANDROID_AVD_HOME=/opt/avd
        ANDROID_EMPTY=
        PLUME_ADB=/opt/sdk/platform-tools/adb
        \(AndroidSDKLocator.endMarker)
        trailing noise ANDROID_HOME=/wrong
        """
        let parsed = AndroidSDKLocator.parseShellOutput(output)
        #expect(parsed.environment == ["ANDROID_HOME": "/opt/sdk", "ANDROID_AVD_HOME": "/opt/avd"])
        #expect(parsed.adbPath == "/opt/sdk/platform-tools/adb")
    }

    @Test func outputWithoutMarkersIsEmpty() {
        let parsed = AndroidSDKLocator.parseShellOutput("ANDROID_HOME=/x")
        #expect(parsed.environment.isEmpty)
        #expect(parsed.adbPath == nil)
    }

    @Test func derivesRootFromADBSymlink() {
        let root = AndroidSDKLocator.sdkRoot(fromADB: "/opt/homebrew/bin/adb") { _ in "/sdk/platform-tools/adb" }
        #expect(root == "/sdk")
        #expect(AndroidSDKLocator.sdkRoot(fromADB: "/usr/bin/adb", resolveSymlinks: { $0 }) == nil)
    }
}

struct AndroidSDKLocatorRunnerTests {
    @Test func capturesOutput() {
        let output = AndroidSDKLocator.runCapturingOutput(executable: "/bin/sh", arguments: ["-c", "echo hi"], timeout: 5)
        #expect(output == "hi\n")
    }

    @Test func timeoutReturnsNilEvenWhenABackgroundedHelperHoldsTheOutput() {
        let start = Date()
        let output = AndroidSDKLocator.runCapturingOutput(
            executable: "/bin/sh", arguments: ["-c", "sleep 30 & echo partial; sleep 30"], timeout: 0.5
        )
        #expect(output == nil)
        #expect(Date().timeIntervalSince(start) < 10)
    }
}
