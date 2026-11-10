import Testing

@testable import Plume

@MainActor
struct UpdateFeedTests {
    @Test func aStableInstallReadsTheInfoPlistFeed() {
        #expect(UpdateFeed.urlString(override: nil, receivesBetaUpdates: false) == nil)
    }

    @Test func aBetaInstallReadsTheBetaFeed() {
        #expect(UpdateFeed.urlString(override: nil, receivesBetaUpdates: true) == UpdateFeed.betaURLString)
    }

    @Test func theDebugOverrideWinsOverBeta() {
        let override = "http://localhost:8000/appcast.xml"
        #expect(UpdateFeed.urlString(override: override, receivesBetaUpdates: true) == override)
        #expect(UpdateFeed.urlString(override: override, receivesBetaUpdates: false) == override)
    }

    @Test func anEmptyOverrideCountsAsUnset() {
        #expect(UpdateFeed.urlString(override: "", receivesBetaUpdates: true) == UpdateFeed.betaURLString)
        #expect(UpdateFeed.urlString(override: "", receivesBetaUpdates: false) == nil)
    }
}
