import Foundation
import Testing

@testable import Plume

/// `HomebrewCaskDetector` against a scratch directory tree, and
/// `UpdateInstallSource.resolve` — the pure half of install-source
/// resolution, factored out so it's testable without touching Sparkle or
/// `AppSettings.shared`.
@MainActor
struct UpdateControllerTests {
    private func makeScratch() throws -> URL {
        let directory = URL.temporaryDirectory.appending(path: "homebrew-cask-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test func noPrefixHasACaskroomIsNotACaskInstall() throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }

        #expect(HomebrewCaskDetector.isCaskInstall(prefixes: [scratch]) == false)
    }

    @Test func aCaskroomPlumeDirectoryIsACaskInstall() throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }

        try FileManager.default.createDirectory(
            at: scratch.appending(path: "Caskroom/plume"),
            withIntermediateDirectories: true
        )

        #expect(HomebrewCaskDetector.isCaskInstall(prefixes: [scratch]) == true)
    }

    @Test func aFileNamedCaskroomPlumeIsNotACaskInstall() throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }

        try FileManager.default.createDirectory(
            at: scratch.appending(path: "Caskroom"),
            withIntermediateDirectories: true
        )
        try Data().write(to: scratch.appending(path: "Caskroom/plume"))

        #expect(HomebrewCaskDetector.isCaskInstall(prefixes: [scratch]) == false)
    }

    @Test func aCaskroomUnderAnySearchedPrefixCounts() throws {
        let first = try makeScratch()
        let second = try makeScratch()
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }

        try FileManager.default.createDirectory(
            at: second.appending(path: "Caskroom/plume"),
            withIntermediateDirectories: true
        )

        #expect(HomebrewCaskDetector.isCaskInstall(prefixes: [first, second]) == true)
    }

    @Test func anExplicitOverrideAlwaysWins() {
        #expect(UpdateInstallSource.resolve(override: .homebrew, isHomebrewInstall: false) == .homebrew)
        #expect(UpdateInstallSource.resolve(override: .plume, isHomebrewInstall: true) == .plume)
    }

    @Test func noOverrideFallsBackToDetection() {
        #expect(UpdateInstallSource.resolve(override: nil, isHomebrewInstall: true) == .homebrew)
        #expect(UpdateInstallSource.resolve(override: nil, isHomebrewInstall: false) == .plume)
    }

    @Test func releaseNotesFormatReadsSparkleThreeFormats() {
        #expect(ReleaseNotesFormat(sparkleFormat: "markdown") == .markdown)
        #expect(ReleaseNotesFormat(sparkleFormat: "plain-text") == .plainText)
        #expect(ReleaseNotesFormat(sparkleFormat: "html") == .html)
    }

    @Test func releaseNotesFormatIsCaseInsensitive() {
        #expect(ReleaseNotesFormat(sparkleFormat: "Markdown") == .markdown)
        #expect(ReleaseNotesFormat(sparkleFormat: "PLAIN-TEXT") == .plainText)
    }

    // SUAppcastItem.m defaults a missing or unrecognized format to "html" —
    // the legacy behavior from before "plain-text"/"markdown" existed — not
    // to markdown or plain text.
    @Test func releaseNotesFormatDefaultsAbsentOrUnrecognizedToHTML() {
        #expect(ReleaseNotesFormat(sparkleFormat: nil) == .html)
        #expect(ReleaseNotesFormat(sparkleFormat: "rtf") == .html)
    }

    @Test func htmlReleaseNotesPlainTextStripsTagsAndDecodesEntities() {
        let stripped = HTMLReleaseNotes.plainText("<p>Fixed &amp; improved <b>Ryan&#39;s</b> &quot;thing&quot;.</p>")
        #expect(stripped == "Fixed & improved Ryan's \"thing\".")
    }

    @Test func homebrewUpgradeScriptUpgradesThenReopensPlume() {
        let script = HomebrewUpgrade.script(brewPath: "/opt/homebrew/bin/brew", bundleID: "com.ryanmoelter.Plume")
        #expect(script.hasPrefix("#!/bin/sh\n"))
        #expect(script.contains("'/opt/homebrew/bin/brew' upgrade --cask ryanmoelter/tap/plume && open -b 'com.ryanmoelter.Plume'"))
    }

    @Test func homebrewBrewPathUsesTheDetectedPrefix() {
        #expect(HomebrewUpgrade.brewPath(homebrewPrefix: URL(fileURLWithPath: "/usr/local")) == "/usr/local/bin/brew")
        #expect(HomebrewUpgrade.brewPath(homebrewPrefix: nil) == "brew")
    }

    @Test func shellQuotingEscapesSingleQuotes() {
        #expect(HomebrewUpgrade.shellQuoted("it's") == "'it'\\''s'")
    }

    @Test func cumulativeNotesKeepOnlyReleasesNewerThanTheHost() throws {
        let html = """
        <style>.sparkle-installed-version ~ section { display: none; }</style>
        <section data-sparkle-version="30">
        <h2>Plume 0.14.0</h2>
        <p>New</p>
        <script type="text/markdown" data-plume-version="0.14.0">
        - New <\\/tag>
        </script>
        </section>
        <section data-sparkle-version="28">
        <h2>0.13.0</h2>
        <script type="text/markdown" data-plume-version="0.13.0">
        - Older
        </script>
        </section>
        <section data-sparkle-version="27">
        <h2>0.12.0</h2>
        <script type="text/markdown" data-plume-version="0.12.0">
        - Installed
        </script>
        </section>
        """
        let releases = try #require(CumulativeReleaseNotes.releases(in: html, hostBuild: "27"))
        #expect(releases.map(\.displayVersion) == ["0.14.0", "0.13.0"])
        #expect(releases.first?.releaseNotes == "- New </tag>")
    }

    @Test func notesWithoutSectionsAreNotCumulative() {
        #expect(CumulativeReleaseNotes.releases(in: "<p>Just one release</p>", hostBuild: "27") == nil)
    }
}
