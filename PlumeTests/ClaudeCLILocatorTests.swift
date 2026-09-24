import Testing
@testable import Plume

/// The probe runs a real login shell, so these assert the contract against
/// names whose presence is certain either way rather than against `claude`,
/// which may or may not be installed on the machine running the tests.
///
/// Serialized because every test here drives the one process-wide cache.
@Suite(.serialized)
struct ClaudeCLILocatorTests {
    @Test func aNameNoShellCanResolveReadsUnavailable() {
        ClaudeCLILocator.invalidate()
        defer { ClaudeCLILocator.invalidate() }

        #expect(!ClaudeCLILocator.isAvailable(commandName: "plume-definitely-not-a-command-x9f2"))
    }

    @Test func aShellBuiltinReadsAvailable() {
        ClaudeCLILocator.invalidate()
        defer { ClaudeCLILocator.invalidate() }

        #expect(ClaudeCLILocator.isAvailable(commandName: "cd"))
    }

    /// Each provider must have its own cached availability result.
    @Test func differentCommandsHaveIndependentCacheEntries() {
        ClaudeCLILocator.invalidate()
        defer { ClaudeCLILocator.invalidate() }

        #expect(ClaudeCLILocator.isAvailable(commandName: "cd"))
        #expect(!ClaudeCLILocator.isAvailable(commandName: "plume-definitely-not-a-command-x9f2"))
        #expect(ClaudeCLILocator.isAvailable(commandName: "cd"))
    }

    @Test func invalidatingRestoresTheProbe() {
        ClaudeCLILocator.invalidate()
        defer { ClaudeCLILocator.invalidate() }

        #expect(ClaudeCLILocator.isAvailable(commandName: "cd"))
        ClaudeCLILocator.invalidate()
        #expect(!ClaudeCLILocator.isAvailable(commandName: "plume-definitely-not-a-command-x9f2"))
    }
}
