import Foundation
import Testing
@testable import Plume

/// A session counts as written elsewhere only when an unowned `claude`
/// process exists *and* the transcript is still changing. Either alone is
/// ordinary: a finished orphan leaves a stale file, and an owned process is
/// this app's own agent.
struct OrphanedSessionDetectorTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    @Test func reportsWrittenWhenUnownedProcessAndFreshTranscript() {
        #expect(OrphanedSessionDetector.isWrittenElsewhere(
            transcriptModifiedAt: now.addingTimeInterval(-5),
            now: now,
            candidatePIDs: [101, 202],
            ownedPIDs: [101]
        ) == true)
    }

    @Test func ignoresProcessesThisAppSpawned() {
        #expect(OrphanedSessionDetector.isWrittenElsewhere(
            transcriptModifiedAt: now.addingTimeInterval(-5),
            now: now,
            candidatePIDs: [101, 202],
            ownedPIDs: [101, 202]
        ) == false)
    }

    @Test func ignoresAnOrphanThatHasStoppedWriting() {
        #expect(OrphanedSessionDetector.isWrittenElsewhere(
            transcriptModifiedAt: now.addingTimeInterval(-OrphanedSessionDetector.writeHorizon - 1),
            now: now,
            candidatePIDs: [202],
            ownedPIDs: []
        ) == false)
    }

    @Test func ignoresMissingTranscript() {
        #expect(OrphanedSessionDetector.isWrittenElsewhere(
            transcriptModifiedAt: nil,
            now: now,
            candidatePIDs: [202],
            ownedPIDs: []
        ) == false)
    }

    @Test func ignoresFreshTranscriptWithNoProcessAtAll() {
        #expect(OrphanedSessionDetector.isWrittenElsewhere(
            transcriptModifiedAt: now,
            now: now,
            candidatePIDs: [],
            ownedPIDs: []
        ) == false)
    }
}
