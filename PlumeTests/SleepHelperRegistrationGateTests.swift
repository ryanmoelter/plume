import Testing
@testable import Plume

struct SleepHelperRegistrationGateTests {
    @Test func releaseAlwaysRegisters() {
        #expect(SleepHelperRegistrationGate.allowsRegistration(isDebugBuild: false, isTestHost: false, debugOptIn: false))
    }

    @Test func debugRegistersOnlyWhenOptedIn() {
        #expect(!SleepHelperRegistrationGate.allowsRegistration(isDebugBuild: true, isTestHost: false, debugOptIn: false))
        #expect(SleepHelperRegistrationGate.allowsRegistration(isDebugBuild: true, isTestHost: false, debugOptIn: true))
    }

    @Test func testHostNeverRegisters() {
        #expect(!SleepHelperRegistrationGate.allowsRegistration(isDebugBuild: true, isTestHost: true, debugOptIn: true))
        #expect(!SleepHelperRegistrationGate.allowsRegistration(isDebugBuild: false, isTestHost: true, debugOptIn: true))
    }
}
