import Foundation
import Testing
@testable import Plume

/// Automatic uses the icons inside a Plume tab or a Ghostty terminal; On and Off ignore the environment. A `Bool` stored before
/// the automatic mode decodes as On or Off. The mode is one global setting:
/// the Projects defaults row's value migrates into it once, a project's is
/// ignored, and the tool reads it from the app's domain.
struct NerdFontModeTests {
    private let tab = ["PLUME_TAB_ID": UUID().uuidString]

    private let ghostty = ["TERM_PROGRAM": "ghostty"]

    @Test func automaticIsOnInsidePlume() {
        #expect(NerdFontMode.usesNerdFont(.automatic, environment: tab))
        #expect(NerdFontMode.usesNerdFont(nil, environment: tab))
    }

    @Test func automaticIsOnInsideGhostty() {
        #expect(NerdFontMode.usesNerdFont(.automatic, environment: ghostty))
        #expect(NerdFontMode.usesNerdFont(nil, environment: ghostty))
    }

    @Test func automaticIsOffElsewhere() {
        #expect(!NerdFontMode.usesNerdFont(.automatic, environment: [:]))
        #expect(!NerdFontMode.usesNerdFont(.automatic, environment: ["PLUME_TAB_ID": ""]))
        #expect(!NerdFontMode.usesNerdFont(.automatic, environment: ["TERM_PROGRAM": "Apple_Terminal"]))
    }

    @Test func onAndOffIgnoreTheEnvironment() {
        for environment in [[:], tab, ghostty] {
            #expect(NerdFontMode.usesNerdFont(.on, environment: environment))
            #expect(!NerdFontMode.usesNerdFont(.off, environment: environment))
        }
    }

    @Test func aStoredBoolDecodes() throws {
        let decoded = try JSONDecoder().decode(ProjectSettings.self, from: Data(#"{"nerdFont":true}"#.utf8))
        #expect(decoded.nerdFont == .on)
        let off = try JSONDecoder().decode(ProjectSettings.self, from: Data(#"{"nerdFont":false}"#.utf8))
        #expect(off.nerdFont == .off)
    }

    @Test func aStoredConfigurationWithBoolsDecodes() throws {
        let json = #"{"defaults":{"nerdFont":true,"branchPrefix":""},"repositories":{"/r":{"nerdFont":false}}}"#
        let decoded = try JSONDecoder().decode(ProjectsConfiguration.self, from: Data(json.utf8))
        #expect(decoded == ProjectsConfiguration(
            defaults: ProjectSettings(branchPrefix: "", nerdFont: .on),
            repositories: ["/r": ProjectSettings(nerdFont: .off)]
        ))
    }

    @Test func everyModeRoundTripsAsAString() throws {
        for mode in NerdFontMode.allCases {
            let data = try JSONEncoder().encode(ProjectSettings(nerdFont: mode))
            #expect(String(decoding: data, as: UTF8.self).contains(#""nerdFont":"\#(mode.rawValue)""#))
            #expect(try JSONDecoder().decode(ProjectSettings.self, from: data).nerdFont == mode)
        }
    }

    @Test func theGlobalModeIsTheStoredOneThenTheDefaultsRowsThenAutomatic() {
        #expect(NerdFontMode.global(stored: "off", legacyDefault: .on) == .off)
        #expect(NerdFontMode.global(stored: "automatic", legacyDefault: .on) == .automatic)
        #expect(NerdFontMode.global(stored: nil, legacyDefault: .on) == .on)
        #expect(NerdFontMode.global(stored: nil, legacyDefault: nil) == .automatic)
        #expect(NerdFontMode.global(stored: "sometimes", legacyDefault: .on) == .automatic)
    }

    // MARK: AppSettings

    private func withDefaults(_ body: (UserDefaults, String) throws -> Void) throws {
        let suite = "NerdFontModeTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults, suite)
    }

    private func store(_ configuration: ProjectsConfiguration, in defaults: UserDefaults) throws {
        defaults.set(try JSONEncoder().encode(configuration), forKey: ProjectsConfiguration.userDefaultsKey)
    }

    @MainActor @Test func theDefaultsRowsModeMigratesOnceAndProjectsAreIgnored() throws {
        try withDefaults { defaults, suite in
            try store(ProjectsConfiguration(
                defaults: ProjectSettings(nerdFont: .off),
                repositories: ["/r": ProjectSettings(nerdFont: .on)]
            ), in: defaults)

            let settings = AppSettings(defaults: defaults, domainName: suite)
            #expect(settings.nerdFontMode == .off)
            #expect(defaults.string(forKey: NerdFontMode.userDefaultsKey) == "off")

            settings.nerdFontMode = .on
            #expect(AppSettings(defaults: defaults, domainName: suite).nerdFontMode == .on)
        }
    }

    @MainActor @Test func nothingStoredIsAutomaticAndStaysUnset() throws {
        try withDefaults { defaults, suite in
            try store(ProjectsConfiguration(repositories: ["/r": ProjectSettings(nerdFont: .on)]), in: defaults)
            let settings = AppSettings(defaults: defaults, domainName: suite)
            #expect(settings.nerdFontMode == .automatic)
            #expect(!settings.hasStoredNerdFontMode)
        }
    }

    @Test func gitConfigImportSetsTheModeOnlyWhenUnset() {
        let imported = ProjectsConfiguration(
            defaults: ProjectSettings(nerdFont: .on),
            repositories: ["/r": ProjectSettings(nerdFont: .off)]
        )
        #expect(GitConfigSettingsImport.nerdFontMode(importing: imported, isStored: false) == .on)
        #expect(GitConfigSettingsImport.nerdFontMode(importing: imported, isStored: true) == nil)
        #expect(GitConfigSettingsImport.nerdFontMode(importing: ProjectsConfiguration(), isStored: false) == nil)

        let merged = GitConfigSettingsImport.merging(imported, into: ProjectsConfiguration())
        #expect(merged == ProjectsConfiguration())
    }

    // MARK: The tool

    @Test func theToolReadsTheGlobalMode() throws {
        try withDefaults { defaults, suite in
            let source = UserDefaultsProjectSettingsSource(suiteName: suite)
            #expect(source.nerdFontMode() == .automatic)

            try store(ProjectsConfiguration(defaults: ProjectSettings(nerdFont: .on)), in: defaults)
            #expect(source.nerdFontMode() == .on)

            defaults.set("off", forKey: NerdFontMode.userDefaultsKey)
            #expect(source.nerdFontMode() == .off)
        }
    }

    @Test func anUnknownModeDecodesAsAutomatic() throws {
        let decoded = try JSONDecoder().decode(ProjectSettings.self, from: Data(#"{"nerdFont":"sometimes","baseBranch":"dev"}"#.utf8))
        #expect(decoded == ProjectSettings(baseBranch: "dev", nerdFont: .automatic))
    }

    // MARK: Settings status

    @Test(arguments: [
        (NerdFontMode.on, true, true),
        (.off, false, false),
        (.automatic, true, false),
    ])
    func iconAvailabilityFollowsTheMode(mode: NerdFontMode, plume: Bool, other: Bool) {
        let availability = mode.iconAvailability
        #expect(availability.plumeAndGhostty == plume)
        #expect(availability.otherTerminals == other)
    }
}
