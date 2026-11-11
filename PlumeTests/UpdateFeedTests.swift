import Testing

@testable import Plume

@MainActor
struct UpdateFeedTests {
    @Test func aStableInstallAllowsOnlyTheDefaultChannel() {
        #expect(UpdateChannel.stable.sparkleChannels.isEmpty)
    }

    /// Must match the `<sparkle:channel>` that `package-release.sh --beta`
    /// writes into the appcast.
    @Test func aBetaInstallAllowsTheBetaChannel() {
        #expect(UpdateChannel.beta.sparkleChannels == ["beta"])
    }

    @Test func theChannelPersistsAsARawString() {
        #expect(UpdateChannel(rawValue: "beta") == .beta)
        #expect(UpdateChannel(rawValue: "stable") == .stable)
        #expect(UpdateChannel(rawValue: "nonsense") == nil)
    }
}
