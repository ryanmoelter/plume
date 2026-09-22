import Foundation
import Testing
@testable import Plume

/// Each background tool announces its launch in prose, and the phrasings vary
/// per tool and per CLI build. These are the shapes the sampled corpus
/// actually contains.
struct BackgroundTaskParsingTests {
    @Test func aMonitorWithAMinuteExpiryReportsIt() throws {
        let started = try #require(BackgroundTaskResult.parse(
            "Monitor started (task bao64idt0, expires in 25m unless the source ends first)."
        ))

        #expect(started.id == "bao64idt0")
        #expect(started.expiry == .seconds(25 * 60))
    }

    @Test func aLongerExpiryIsReadTheSameWay() throws {
        let started = try #require(BackgroundTaskResult.parse(
            "Monitor started (task b4e6lw1gs, expires in 30m unless the source ends first)."
        ))

        #expect(started.expiry == .seconds(30 * 60))
    }

    @Test func aTimeoutIsReadInMilliseconds() throws {
        let started = try #require(BackgroundTaskResult.parse(
            "Monitor started (task b7hk5cik9, timeout 1800000ms). You will be notified on each event."
        ))

        #expect(started.id == "b7hk5cik9")
        #expect(started.expiry == .seconds(1800))
    }

    /// A persistent monitor declares no end at all, so the hard cap is the
    /// only thing that ever stops it holding the Mac awake.
    @Test func aPersistentMonitorDeclaresNoExpiry() throws {
        let started = try #require(BackgroundTaskResult.parse(
            "Monitor started (task bhns1z46o, persistent — runs until TaskStop or session end)."
        ))

        #expect(started.id == "bhns1z46o")
        #expect(started.expiry == nil)
    }

    /// The acknowledgement names the same id again inside an output path, so
    /// a parser that scanned for the id rather than reading the sentence
    /// would pick up a path fragment.
    @Test func aBackgroundCommandTakesItsIDFromTheSentenceNotThePath() throws {
        let started = try #require(BackgroundTaskResult.parse("""
        Command running in background with ID: b000iiw3u. Output is being written to: \
        /private/tmp/claude-501/-Users-ryanmoelter-Development-Plume/8c37f2a5/tasks/b000iiw3u.output. \
        You will be notified when it completes.
        """))

        #expect(started.id == "b000iiw3u")
        #expect(started.expiry == nil)
    }

    @Test func anAsyncAgentReportsItsAgentID() throws {
        let started = try #require(BackgroundTaskResult.parse(
            "Async agent launched successfully. agentId: a9f6aae3ce9a5e485 (Write poem stanza 1 of 4)"
        ))

        #expect(started.id == "a9f6aae3ce9a5e485")
        #expect(started.description == "Write poem stanza 1 of 4")
    }

    /// A build that explains the id in that parenthesis rather than naming
    /// the agent's task puts a sentence where a title goes.
    @Test func anIDExplanationIsNotATitle() throws {
        let started = try #require(BackgroundTaskResult.parse("""
        agentId: a9f6aae3ce9a5e485 (internal ID - do not mention to user. Use SendMessage to continue this agent.)
        """))

        #expect(started.description == nil)
    }

    /// Neither the Monitor nor the Bash acknowledgement names what the task
    /// is for, so the scanner has to take it from the call instead.
    @Test func theMonitorAndBashAcknowledgementsNameNoDescription() throws {
        let monitor = try #require(BackgroundTaskResult.parse(
            "Monitor started (task b7hk5cik9, timeout 1800000ms). You will be notified on each event."
        ))
        let command = try #require(BackgroundTaskResult.parse(
            "Command running in background with ID: b000iiw3u. Output is being written to: /tmp/b000iiw3u.output."
        ))

        #expect(monitor.description == nil)
        #expect(command.description == nil)
    }

    @Test func ordinaryToolOutputStartsNothing() {
        #expect(BackgroundTaskResult.parse("") == nil)
        #expect(BackgroundTaskResult.parse("The file was written.") == nil)
        #expect(BackgroundTaskResult.parse("Monitor started") == nil)
        #expect(BackgroundTaskResult.parse("Command running in background with ID: ") == nil)
    }
}
