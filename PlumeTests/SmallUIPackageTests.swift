import CoreGraphics
import Foundation
import Testing
@testable import Plume

struct ReleaseNotesLinkTests {
    @Test func stableVersionLinksToItsTag() {
        let url = ReleaseNotesLink.url(marketingVersion: "0.19.1", isDebugBuild: false)
        #expect(url.absoluteString == "https://github.com/ryanmoelter/plume/releases/tag/v0.19.1")
    }

    @Test func betaKeepsItsSuffix() {
        let url = ReleaseNotesLink.url(marketingVersion: "0.20.0-beta.1", isDebugBuild: false)
        #expect(url.absoluteString == "https://github.com/ryanmoelter/plume/releases/tag/v0.20.0-beta.1")
    }

    @Test func debugBuildLinksToTheReleasesList() {
        #expect(ReleaseNotesLink.url(marketingVersion: "0.19.1", isDebugBuild: true) == ReleaseNotesLink.releasesList)
    }

    @Test func missingVersionLinksToTheReleasesList() {
        #expect(ReleaseNotesLink.url(marketingVersion: nil, isDebugBuild: false) == ReleaseNotesLink.releasesList)
        #expect(ReleaseNotesLink.url(marketingVersion: " ", isDebugBuild: false) == ReleaseNotesLink.releasesList)
    }
}

struct PullRequestDestinationTests {
    private let pull = URL(string: "https://github.com/owner/repo/pull/123")!

    @Test func linearDiffsSwapsTheHost() {
        #expect(PullRequestDestination.linearDiffs.openingURL(for: pull).absoluteString == "https://linear.review/owner/repo/pull/123")
    }

    @Test func linearDiffsDropsFilesTabAndFragment() {
        let url = URL(string: "https://github.com/owner/repo/pull/123/files?w=1#diff-abc")!
        #expect(PullRequestDestination.linearDiffs.openingURL(for: url).absoluteString == "https://linear.review/owner/repo/pull/123")
    }

    @Test func githubLeavesTheURLAlone() {
        #expect(PullRequestDestination.github.openingURL(for: pull) == pull)
    }

    @Test func linearDiffsLeavesOtherURLsAlone() {
        for raw in [
            "https://github.com/owner/repo",
            "https://github.com/owner/repo/issues/12",
            "https://github.com/owner/repo/pull/new",
            "https://gitlab.com/owner/repo/-/merge_requests/4",
            "https://example.com/owner/repo/pull/1",
        ] {
            let url = URL(string: raw)!
            #expect(PullRequestDestination.linearDiffs.openingURL(for: url) == url)
        }
    }
}

struct DeviceToolbarPlacementTests {
    private let phone: CGFloat = 9.0 / 20.0

    @Test func shortWideTabPutsPortraitPhoneToolbarOnTheSide() {
        #expect(DeviceToolbarPlacement.choose(tabSize: CGSize(width: 1200, height: 500), deviceAspect: phone) == .leading)
    }

    @Test func tallNarrowTabKeepsToolbarOnTop() {
        #expect(DeviceToolbarPlacement.choose(tabSize: CGSize(width: 400, height: 900), deviceAspect: phone) == .top)
    }

    @Test func landscapeDeviceLimitedByWidthKeepsToolbarOnTop() {
        let landscape = DeviceToolbarPlacement.aspect(of: CGSize(width: 1080, height: 2400), rotation: .landscape)
        #expect(DeviceToolbarPlacement.choose(tabSize: CGSize(width: 500, height: 600), deviceAspect: landscape) == .top)
    }

    @Test func landscapeDeviceLimitedByHeightTakesTheSide() {
        let landscape = DeviceToolbarPlacement.aspect(of: CGSize(width: 1080, height: 2400), rotation: .landscape)
        #expect(DeviceToolbarPlacement.choose(tabSize: CGSize(width: 1200, height: 500), deviceAspect: landscape) == .leading)
    }

    @Test func unknownAspectOrSizeStaysOnTop() {
        #expect(DeviceToolbarPlacement.choose(tabSize: CGSize(width: 1200, height: 500), deviceAspect: nil) == .top)
        #expect(DeviceToolbarPlacement.choose(tabSize: .zero, deviceAspect: phone) == .top)
    }

    @Test func aspectFollowsRotation() {
        let size = CGSize(width: 1000, height: 2000)
        #expect(DeviceToolbarPlacement.aspect(of: size, rotation: .portrait) == 0.5)
        #expect(DeviceToolbarPlacement.aspect(of: size, rotation: .reverseLandscape) == 2)
        #expect(DeviceToolbarPlacement.aspect(of: nil, rotation: .portrait) == nil)
    }
}
