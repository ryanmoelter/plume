import Foundation
import Testing
@testable import Plume

/// The retired Settings ▸ Integrations list joins the end of the Projects
/// defaults row's list, and of every project row's own list, without
/// duplicates or blanks. Its key is deleted so the move happens once.
@MainActor
struct LegacyIgnoredChecksMigrationTests {
    private let suite = "plume-ignored-migration-\(UUID().uuidString)"
    private let legacyKey = "ignoredPendingChecks"

    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    @Test func fillsAnUnsetDefaultsList() {
        let migrated = AppSettings.addingLegacyIgnoredPendingChecks(["a", "b"], to: ProjectsConfiguration())
        #expect(migrated.defaults.ignoredPendingChecks == ["a", "b"])
    }

    @Test func appendsAfterTheExistingListWithoutDuplicates() {
        let existing = ProjectsConfiguration(defaults: ProjectSettings(ignoredPendingChecks: ["git", "shared"]))
        let migrated = AppSettings.addingLegacyIgnoredPendingChecks(["shared", "plume", " ", "plume"], to: existing)
        #expect(migrated.defaults.ignoredPendingChecks == ["git", "shared", "plume"])
    }

    @Test func anEmptyListLeavesTheDefaultsUnset() {
        let migrated = AppSettings.addingLegacyIgnoredPendingChecks(["", "  "], to: ProjectsConfiguration())
        #expect(migrated.defaults.ignoredPendingChecks == nil)
    }

    /// A project's own list replaces the inherited one, so without the
    /// legacy names it would stop ignoring them.
    @Test func aProjectRowWithItsOwnListGainsTheLegacyNames() {
        let existing = ProjectsConfiguration(repositories: ["/r": ProjectSettings(ignoredPendingChecks: ["mine", "plume"])])
        let migrated = AppSettings.addingLegacyIgnoredPendingChecks(["plume", "other"], to: existing)
        #expect(migrated.repositories["/r"]?.ignoredPendingChecks == ["mine", "plume", "other"])
        #expect(migrated.settings(forRepository: "/r").ignoredPendingChecks == ["mine", "plume", "other"])
    }

    @Test func aProjectRowThatInheritsTheListKeepsInheriting() {
        let existing = ProjectsConfiguration(repositories: ["/r": ProjectSettings(baseBranch: "trunk")])
        let migrated = AppSettings.addingLegacyIgnoredPendingChecks(["plume"], to: existing)
        #expect(migrated.repositories == existing.repositories)
        #expect(migrated.settings(forRepository: "/r").ignoredPendingChecks == ["plume"])
    }

    @Test func migratingMovesTheListAndDeletesTheKey() throws {
        try withDefaults { defaults in
            defaults.set(["plume"], forKey: legacyKey)
            let settings = AppSettings(defaults: defaults, domainName: suite)
            settings.projectsConfiguration.defaults.ignoredPendingChecks = ["git"]

            settings.migrateLegacyIgnoredPendingChecks()

            #expect(settings.projectsConfiguration.defaults.ignoredPendingChecks == ["git", "plume"])
            #expect(defaults.object(forKey: legacyKey) == nil)
            #expect(AppSettings(defaults: defaults, domainName: suite).projectsConfiguration.defaults.ignoredPendingChecks == ["git", "plume"])
        }
    }

    @Test func migratingTwiceChangesNothing() throws {
        try withDefaults { defaults in
            defaults.set(["plume"], forKey: legacyKey)
            let settings = AppSettings(defaults: defaults, domainName: suite)
            settings.migrateLegacyIgnoredPendingChecks()
            settings.projectsConfiguration.defaults.ignoredPendingChecks = []

            settings.migrateLegacyIgnoredPendingChecks()

            #expect(settings.projectsConfiguration.defaults.ignoredPendingChecks == [])
        }
    }

    @Test func noLegacyKeyChangesNothing() throws {
        try withDefaults { defaults in
            let settings = AppSettings(defaults: defaults, domainName: suite)
            settings.migrateLegacyIgnoredPendingChecks()
            #expect(settings.projectsConfiguration == ProjectsConfiguration())
        }
    }
}

/// A project's unset list shows the defaults row's names as inherited, and
/// "Use Default" appears only once the project has its own list. The
/// defaults row has nothing to inherit, so it never offers it.
struct NameListDisplayTests {
    @Test func anUnsetProjectListShowsTheInheritedNames() {
        let display = NameListDisplay(own: nil, inherited: ["a", "b"], isDefaults: false)
        #expect(display.names == ["a", "b"])
        #expect(display.isInherited)
        #expect(!display.offersUseDefault)
    }

    @Test func aProjectsOwnListReplacesTheInheritedOne() {
        let display = NameListDisplay(own: ["mine"], inherited: ["a"], isDefaults: false)
        #expect(display.names == ["mine"])
        #expect(!display.isInherited)
        #expect(display.offersUseDefault)
    }

    @Test func anEmptiedProjectListStaysItsOwn() {
        let display = NameListDisplay(own: [], inherited: ["a"], isDefaults: false)
        #expect(display.names.isEmpty)
        #expect(display.offersUseDefault)
    }

    @Test func theDefaultsRowNeverInheritsOrOffersUseDefault() {
        for own in [nil, ["a"]] as [[String]?] {
            let display = NameListDisplay(own: own, inherited: [], isDefaults: true)
            #expect(display.names == (own ?? []))
            #expect(!display.isInherited)
            #expect(!display.offersUseDefault)
        }
    }

    @Test func editsStartFromTheInheritedNames() {
        let display = NameListDisplay(own: nil, inherited: ["a", "b"], isDefaults: false)
        #expect(display.adding("c, a, ,d") == ["a", "b", "c", "d"])
        #expect(display.removing("a") == ["b"])
    }
}
