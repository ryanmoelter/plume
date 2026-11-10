import Testing

@testable import Plume

@MainActor
struct UpdateFeedTests {
    @Test func aStableInstallReadsTheInfoPlistFeed() {
        #expect(UpdateFeed.urlString(override: nil, channel: .stable) == nil)
    }

    @Test func aBetaInstallReadsTheBetaFeed() {
        #expect(UpdateFeed.urlString(override: nil, channel: .beta) == UpdateFeed.betaURLString)
    }

    @Test func theChannelPersistsAsARawString() {
        #expect(UpdateChannel(rawValue: "beta") == .beta)
        #expect(UpdateChannel(rawValue: "stable") == .stable)
        #expect(UpdateChannel(rawValue: "nonsense") == nil)
    }

    @Test func theDebugOverrideWinsOverBeta() {
        let override = "http://localhost:8000/appcast.xml"
        #expect(UpdateFeed.urlString(override: override, channel: .beta) == override)
        #expect(UpdateFeed.urlString(override: override, channel: .stable) == override)
    }

    @Test func anEmptyOverrideCountsAsUnset() {
        #expect(UpdateFeed.urlString(override: "", channel: .beta) == UpdateFeed.betaURLString)
        #expect(UpdateFeed.urlString(override: "", channel: .stable) == nil)
    }
}
