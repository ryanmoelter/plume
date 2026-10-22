import Foundation
import Testing
@testable import Plume

/// Merge, cursor, pruning and serialization of one workspace's issue cache,
/// and the disk actor's ordering of late writes.
struct LinearSyncCacheTests {
    private let base = Date(timeIntervalSince1970: 1_790_000_000)

    private func snapshot(
        _ identifier: String,
        id: String? = nil,
        title: String = "An issue",
        at offset: TimeInterval = 0,
        state: LinearWorkflowState = LinearTestFixtures.todoState,
        assignee: LinearUser? = nil,
        isTrashed: Bool = false
    ) -> LinearIssueSnapshot {
        let teamKey = LinearIdentifier.teamKey(of: identifier)
        return LinearIssueSnapshot(
            id: id ?? "id-\(identifier)",
            updatedAt: base.addingTimeInterval(offset),
            archivedAt: nil,
            isTrashed: isTrashed,
            state: state,
            assignee: assignee,
            teamID: "team-\(teamKey)",
            issue: LinearIssue(
                identifier: identifier,
                title: title,
                url: "https://linear.app/x/issue/\(identifier)",
                stateName: state.name,
                stateType: state.type,
                stateColor: state.color,
                assigneeName: assignee?.name,
                teamKey: teamKey
            )
        )
    }

    @Test func anOlderSnapshotNeverReplacesANewerOne() {
        var cache = LinearSyncCache(orgID: "A")
        cache.upsert(snapshot("P-1", title: "New", at: 10))
        cache.upsert(snapshot("P-1", title: "Old", at: 5))
        #expect(cache.issue(identifier: "p-1")?.title == "New")
    }

    @Test func reapplyingTheSameSnapshotAtTheCursorEdgeIsIdempotent() {
        var cache = LinearSyncCache(orgID: "A")
        let issue = snapshot("P-1", at: 10)
        cache.applyDelta([issue], complete: true, queriedFrom: base)
        let once = cache
        cache.applyDelta([issue], complete: true, queriedFrom: base.addingTimeInterval(10 - LinearSyncCache.overlap))
        #expect(cache == once)
    }

    @Test func aTrashedSnapshotRemovesTheIssue() {
        var cache = LinearSyncCache(orgID: "A")
        cache.upsert(snapshot("P-1", at: 1))
        cache.upsert(snapshot("P-1", at: 2, isTrashed: true))
        #expect(cache.issue(identifier: "P-1") == nil)
        #expect(cache.issues.isEmpty)
    }

    @Test func aMovedIssueStillAnswersToItsOldIdentifier() {
        var cache = LinearSyncCache(orgID: "A")
        cache.upsert(snapshot("OLD-1", id: "x", at: 1))
        cache.upsert(snapshot("NEW-7", id: "x", at: 2))
        #expect(cache.issue(identifier: "NEW-7")?.identifier == "NEW-7")
        #expect(cache.issue(identifier: "OLD-1")?.identifier == "NEW-7")
        #expect(cache.issues.count == 1)
    }

    @Test func aLookupRecordsTheIdentifierItWasRequestedAs() {
        var cache = LinearSyncCache(orgID: "A")
        cache.upsert(snapshot("NEW-7", id: "x", at: 1), requestedAs: "old-1")
        #expect(cache.issue(identifier: "OLD-1")?.identifier == "NEW-7")
        cache.removeIssue(identifier: "OLD-1")
        #expect(cache.issue(identifier: "NEW-7") == nil)
    }

    @Test func theCursorIsTheNewestUpdateOrTheBoundOfAnEmptyFirstSync() {
        var cache = LinearSyncCache(orgID: "A")
        let now = base.addingTimeInterval(100)
        #expect(cache.deltaLowerBound(now: now) == now.addingTimeInterval(-LinearSyncCache.backfillWindow))

        let bound = cache.deltaLowerBound(now: now)
        cache.applyDelta([], complete: true, queriedFrom: bound)
        #expect(cache.cursor == bound)

        cache.applyDelta([snapshot("P-1", at: 30), snapshot("P-2", at: 20)], complete: true, queriedFrom: bound)
        #expect(cache.cursor == base.addingTimeInterval(30))
        #expect(cache.deltaLowerBound(now: now) == base.addingTimeInterval(30 - LinearSyncCache.overlap))

        cache.applyDelta([], complete: true, queriedFrom: cache.deltaLowerBound(now: now))
        #expect(cache.cursor == base.addingTimeInterval(30))
    }

    @Test func anIncompleteDeltaDropsEverythingItDidNotCover() {
        var cache = LinearSyncCache(orgID: "A")
        cache.applyDelta([snapshot("P-1", at: 1), snapshot("P-2", at: 2)], complete: true, queriedFrom: base)
        cache.applyDelta([snapshot("P-3", at: 50), snapshot("P-2", at: 40)], complete: false, queriedFrom: base)
        #expect(cache.issue(identifier: "P-1") == nil)
        #expect(cache.issue(identifier: "P-2") != nil)
        #expect(cache.issue(identifier: "P-3") != nil)
        #expect(cache.cursor == base.addingTimeInterval(50))
    }

    @Test func aRenamedStateReachesEveryIssueInIt() {
        var cache = LinearSyncCache(orgID: "A")
        cache.upsert(snapshot("P-1", at: 1))
        let renamed = LinearWorkflowState(id: LinearTestFixtures.todoState.id, name: "Ready", type: .unstarted, color: "#ffffff")
        let team = LinearTeam(id: "team-P", key: "P", name: "P", states: [renamed])
        cache.install(LinearCatalog(orgID: "A", teams: [team], fetchedAt: base))
        #expect(cache.issue(identifier: "P-1")?.stateName == "Ready")
        #expect(cache.issue(identifier: "P-1")?.stateColor == "#ffffff")
    }

    @Test func pruningKeepsWantedAndRecentIssuesAndDropsOrphanedUsers() {
        var cache = LinearSyncCache(orgID: "A")
        let ann = LinearUser(id: "u-ann", name: "Ann")
        let bob = LinearUser(id: "u-bob", name: "Bob")
        cache.upsert(snapshot("P-1", at: 0, assignee: ann))
        cache.upsert(snapshot("P-2", at: 0, assignee: bob))
        cache.upsert(snapshot("P-3", at: LinearSyncCache.retention))
        cache.prune(keeping: ["P-2"], now: base.addingTimeInterval(LinearSyncCache.retention + 1))
        #expect(cache.issue(identifier: "P-1") == nil)
        #expect(cache.issue(identifier: "P-2")?.assigneeName == "Bob")
        #expect(cache.issue(identifier: "P-3") != nil)
        #expect(cache.users.keys.sorted() == ["u-bob"])
    }

    @Test func aRoundTripThroughJSONKeepsTheIdentifierIndex() throws {
        var cache = LinearSyncCache(orgID: "A")
        cache.applyDelta(
            [snapshot("P-1", at: 1, assignee: LinearUser(id: "u", name: "Ann")), snapshot("NEW-2", id: "m", at: 2)],
            complete: true,
            queriedFrom: base
        )
        cache.upsert(snapshot("NEW-2", id: "m", at: 2), requestedAs: "OLD-2")
        let decoded = try JSONDecoder().decode(LinearSyncCache.self, from: JSONEncoder().encode(cache))
        #expect(decoded == cache)
        #expect(decoded.issue(identifier: "P-1")?.assigneeName == "Ann")
        #expect(decoded.issue(identifier: "OLD-2")?.identifier == "NEW-2")
    }

    @Test func absorbingADiskCopyKeepsTheNewerIssueAndTakesItsCursor() {
        var disk = LinearSyncCache(orgID: "A")
        disk.applyDelta([snapshot("P-1", title: "Disk", at: 1), snapshot("P-2", at: 1)], complete: true, queriedFrom: base)
        var memory = LinearSyncCache(orgID: "A")
        memory.upsert(snapshot("P-1", title: "Network", at: 5))

        memory.absorb(disk)

        #expect(memory.issue(identifier: "P-1")?.title == "Network")
        #expect(memory.issue(identifier: "P-2") != nil)
        #expect(memory.cursor == disk.cursor)
    }

    // MARK: Disk

    private func scratchDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "LinearSyncCacheTests-\(UUID().uuidString)")
    }

    @Test func aLateWriteNeverOverwritesANewerOne() async {
        let directory = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = LinearCacheDisk(directory: directory)
        var newer = LinearSyncCache(orgID: "A")
        newer.upsert(snapshot("P-1", at: 2))

        await disk.save(newer, sequence: 2)
        await disk.save(LinearSyncCache(orgID: "A"), sequence: 1)

        #expect(await disk.loadIssues(orgID: "A") == newer)
    }

    @Test func aWriteOlderThanARemovalNeverRecreatesTheFile() async {
        let directory = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = LinearCacheDisk(directory: directory)

        await disk.save(LinearSyncCache(orgID: "A"), sequence: 1)
        await disk.remove(orgID: "A", sequence: 3)
        await disk.save(LinearSyncCache(orgID: "A"), sequence: 2)

        #expect(await disk.loadIssues(orgID: "A") == nil)
    }

    @Test func aCacheFromAnotherFormatVersionIsDiscarded() async throws {
        let directory = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = LinearCacheDisk(directory: directory)
        await disk.save(LinearSyncCache(orgID: "A"), sequence: 1)
        let file = disk.issuesFile(orgID: "A")
        let json = try String(contentsOf: file, encoding: .utf8)
            .replacingOccurrences(of: "\"formatVersion\":\(LinearSyncCache.formatVersion)", with: "\"formatVersion\":999")
        try json.write(to: file, atomically: true, encoding: .utf8)

        #expect(await disk.loadIssues(orgID: "A") == nil)
    }
}
