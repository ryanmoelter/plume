import Testing
@testable import Plume

/// Asserts the fixture catalog stays complete as the enums it exercises
/// grow. This is the reason to build a catalog rather than a hardcoded
/// blob: a newly added `PullRequestFetchState` or `TaskStatus` case fails
/// here instead of silently going unseeded.
struct SidebarFixtureCatalogTests {
    @Test func everyPullRequestFetchStateCaseIsCovered() {
        #expect(
            SidebarFixtureCatalog.coveredPullRequestFetchStateCases
                == SidebarFixtureCatalog.allPullRequestFetchStateCaseNames
        )
    }

    @Test func everyTaskStatusIsCovered() {
        #expect(SidebarFixtureCatalog.coveredTaskStatuses == Set(TaskStatus.allCases))
    }

    @Test func everyCaseHasAUniqueDirectory() {
        let directories = SidebarFixtureCatalog.cases.map(\.directory)
        #expect(directories.count == Set(directories).count)
    }
}
