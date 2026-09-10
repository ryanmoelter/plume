import Foundation
import SwiftUI
import Testing
@testable import Plume

struct ElapsedTimeTests {
    @Test(arguments: [
        (0.0, "0s"),
        (1.4, "1s"),
        (59.0, "59s"),
        (60.0, "1m"),
        (3599.0, "59m"),
        (3600.0, "1h"),
        (5400.0, "1h 30m"),
    ])
    func readsCoarsely(elapsed: TimeInterval, expected: String) {
        #expect(ElapsedTime.formatted(elapsed) == expected)
    }

    /// A clock that has not started yet must not count backwards.
    @Test func negativeElapsedReadsAsZero() {
        #expect(ElapsedTime.formatted(-5) == "0s")
    }

    /// Once the text only changes by the minute, so should the redraw.
    @Test func theTickSlowsOnceSecondsStopShowing() {
        #expect(ElapsedTime.tickInterval(for: 10) == 1)
        #expect(ElapsedTime.tickInterval(for: 120) == 60)
    }
}

struct ElapsedScheduleTests {
    /// The schedule has to slow down as the clock ages. A fixed-rate
    /// `.periodic` would keep a label that started young redrawing every
    /// second forever.
    @Test func theRateDropsOnceTheTextStopsCountingSeconds() {
        let since = Date(timeIntervalSinceReferenceDate: 0)
        let schedule = ElapsedSchedule(since: since)

        var entries = schedule.entries(from: since, mode: .normal)
        let early = (0..<3).compactMap { _ in entries.next() }
        #expect(early[1].timeIntervalSince(early[0]) == 1)

        var later = schedule.entries(from: since.addingTimeInterval(600), mode: .normal)
        let aged = (0..<3).compactMap { _ in later.next() }
        #expect(aged[1].timeIntervalSince(aged[0]) == 60)
    }

    @Test func entriesAlwaysMoveForward() {
        let since = Date(timeIntervalSinceReferenceDate: 0)
        var entries = ElapsedSchedule(since: since).entries(from: since, mode: .normal)
        let dates = (0..<120).compactMap { _ in entries.next() }

        #expect(dates == dates.sorted())
        #expect(Set(dates).count == dates.count)
    }
}

struct WorkingVerbTests {
    @Test func everyVerbIsAPresentParticiple() {
        #expect(!WorkingVerb.all.isEmpty)
        for verb in WorkingVerb.all {
            #expect(verb.hasSuffix("ing") || verb.hasSuffix("in'"), "\(verb)")
        }
    }

    @Test func aTurnKeepsTheSameVerbThroughout() {
        let started = Date()
        #expect(WorkingVerb.forTurn(startedAt: started) == WorkingVerb.forTurn(startedAt: started))
    }

    /// The verb comes from the start time, so turns starting at different
    /// moments do not all say the same thing.
    @Test func differentTurnsGetDifferentVerbs() {
        let base = Date(timeIntervalSinceReferenceDate: 0)
        let verbs = (0..<40).map { WorkingVerb.forTurn(startedAt: base.addingTimeInterval(Double($0))) }
        #expect(Set(verbs).count > 1)
    }

    @Test func aDateBeforeTheReferenceEpochStillPicksAVerb() {
        let ancient = Date(timeIntervalSinceReferenceDate: -1_000_000)
        #expect(WorkingVerb.all.contains(WorkingVerb.forTurn(startedAt: ancient)))
    }
}

@MainActor
struct StatusEngineClockTests {
    @Test func workingStartsTheClock() {
        let engine = StatusEngine()
        let (task, tab) = (UUID(), UUID())

        engine.setStatus(.working, taskID: task, tabID: tab)

        #expect(engine.workStarted(forTab: tab) != nil)
    }

    @Test func settlingStopsTheClock() {
        let engine = StatusEngine()
        let (task, tab) = (UUID(), UUID())
        engine.setStatus(.working, taskID: task, tabID: tab)

        engine.setStatus(.awaitingReply, taskID: task, tabID: tab)

        #expect(engine.workStarted(forTab: tab) == nil)
    }

    /// A tab waiting on the user is not working, so its clock stops rather
    /// than counting time the agent is not spending.
    @Test func waitingOnTheUserStopsTheClock() {
        let engine = StatusEngine()
        let (task, tab) = (UUID(), UUID())
        engine.setStatus(.working, taskID: task, tabID: tab)

        engine.setStatus(.planApproval, taskID: task, tabID: tab)

        #expect(engine.workStarted(forTab: tab) == nil)
    }

    /// Subagents raise a settled tab to working, and the clock follows the
    /// status the user actually sees.
    @Test func workingSubagentsStartTheClockToo() {
        let engine = StatusEngine()
        let (task, tab) = (UUID(), UUID())
        engine.register(tabID: tab, taskID: task)
        engine.setStatus(.awaitingReply, taskID: task, tabID: tab)
        #expect(engine.workStarted(forTab: tab) == nil)

        engine.setSubagentActivity(tabID: tab, working: true)

        #expect(engine.workStarted(forTab: tab) != nil)
    }

    /// Staying at working across events must not restart the count.
    @Test func continuingToWorkKeepsTheOriginalStart() {
        let engine = StatusEngine()
        let (task, tab) = (UUID(), UUID())
        engine.setStatus(.working, taskID: task, tabID: tab)
        let first = engine.workStarted(forTab: tab)

        engine.setStatus(.working, taskID: task, tabID: tab)

        #expect(engine.workStarted(forTab: tab) == first)
    }

    /// A task reports the longest-running of its tabs, so a collapsed row
    /// tells the user how long the work has really been going.
    @Test func aTaskReportsItsOldestRunningClock() {
        let engine = StatusEngine()
        let task = UUID()
        let (older, newer) = (UUID(), UUID())

        engine.setStatus(.working, taskID: task, tabID: older)
        let oldest = engine.workStarted(forTab: older)
        engine.setStatus(.working, taskID: task, tabID: newer)

        #expect(engine.workStarted(forTask: task) == oldest)
    }

    @Test func aTaskWithNothingRunningHasNoClock() {
        let engine = StatusEngine()
        let (task, tab) = (UUID(), UUID())
        engine.setStatus(.awaitingReply, taskID: task, tabID: tab)

        #expect(engine.workStarted(forTask: task) == nil)
    }

    @Test func forgettingATabDropsItsClock() {
        let engine = StatusEngine()
        let (task, tab) = (UUID(), UUID())
        engine.setStatus(.working, taskID: task, tabID: tab)

        engine.forget(tabID: tab, taskID: task)

        #expect(engine.workStarted(forTab: tab) == nil)
    }
}
