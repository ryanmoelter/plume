import Foundation
import Testing

@testable import Plume

/// The slash-command list remembered per directory between sessions, which is
/// what a tab with no session yet autocompletes from.
@MainActor
struct SlashCommandMemoryTests {
    private func makeDefaults() -> UserDefaults {
        let defaults = UserDefaults(suiteName: "SlashCommandMemoryTests.\(UUID().uuidString)")!
        defaults.removePersistentDomain(forName: defaults.description)
        return defaults
    }

    private func command(_ name: String) -> SlashCommand {
        SlashCommand(name: name, description: "", argumentHint: "")
    }

    @Test func startsEmptyWithNothingRemembered() {
        #expect(SlashCommandMemory(defaults: makeDefaults()).commands(inDirectory: "/repo").isEmpty)
    }

    @Test func aRememberedListSurvivesIntoTheNextLaunch() {
        let defaults = makeDefaults()
        SlashCommandMemory(defaults: defaults).remember([
            SlashCommand(name: "compact", description: "Compact the context", argumentHint: "[instructions]")
        ], inDirectory: "/repo")

        let reloaded = SlashCommandMemory(defaults: defaults)
        #expect(reloaded.commands(inDirectory: "/repo") == [
            SlashCommand(name: "compact", description: "Compact the context", argumentHint: "[instructions]")
        ])
    }

    /// The bug this keying fixes: one project's project-scoped commands were
    /// offered in every other project.
    @Test func twoDirectoriesKeepSeparateLists() {
        let memory = SlashCommandMemory(defaults: makeDefaults())
        memory.remember([command("compact"), command("deploy")], inDirectory: "/repo")
        memory.remember([command("compact"), command("migrate")], inDirectory: "/other")

        #expect(memory.commands(inDirectory: "/repo").map(\.name) == ["compact", "deploy"])
        #expect(memory.commands(inDirectory: "/other").map(\.name) == ["compact", "migrate"])
    }

    /// Nothing has reported there yet, which is the cold-start behaviour
    /// rather than a missing list.
    @Test func anUnknownDirectoryOffersNothing() {
        let memory = SlashCommandMemory(defaults: makeDefaults())
        memory.remember([command("compact")], inDirectory: "/repo")

        #expect(memory.commands(inDirectory: "/elsewhere").isEmpty)
        #expect(memory.commands(inDirectory: nil).isEmpty)
    }

    /// Without a directory there is no key to file the list under, and
    /// guessing one is the bug.
    @Test func aReportWithNoDirectoryIsNotRemembered() {
        let memory = SlashCommandMemory(defaults: makeDefaults())

        memory.remember([command("compact")], inDirectory: nil)

        #expect(memory.entries.isEmpty)
    }

    /// `initialize` reports on every launch, so a command the user has since
    /// deleted must not linger from the previous list.
    @Test func aLaterReportReplacesAStaleList() {
        let memory = SlashCommandMemory(defaults: makeDefaults())
        memory.remember([command("compact"), command("deploy")], inDirectory: "/repo")

        memory.remember([command("compact")], inDirectory: "/repo")

        #expect(memory.commands(inDirectory: "/repo").map(\.name) == ["compact"])
    }

    /// An absent `commands` array says nothing about the installation, so it
    /// must not read as "this CLI has no commands".
    @Test func anEmptyReportKeepsWhatWasRemembered() {
        let memory = SlashCommandMemory(defaults: makeDefaults())
        memory.remember([command("compact")], inDirectory: "/repo")

        memory.remember([], inDirectory: "/repo")

        #expect(memory.commands(inDirectory: "/repo").map(\.name) == ["compact"])
    }

    /// Plume's own commands are listed from `PlumeSlashCommand.all`, and
    /// storing them would make them come back as CLI commands.
    @Test func plumeProvidedCommandsAreNeverRemembered() {
        let memory = SlashCommandMemory(defaults: makeDefaults())

        memory.remember(PlumeSlashCommand.all, inDirectory: "/repo")

        #expect(memory.commands(inDirectory: "/repo").isEmpty)
    }

    @Test func theOldestDirectoryFallsOffOnceTheListIsFull() {
        let defaults = makeDefaults()
        let memory = SlashCommandMemory(defaults: defaults)
        for index in 0...SlashCommandMemory.capacity {
            memory.remember([command("compact")], inDirectory: "/repo/\(index)")
        }

        #expect(memory.entries.count == SlashCommandMemory.capacity)
        #expect(memory.commands(inDirectory: "/repo/0").isEmpty)
        #expect(memory.commands(inDirectory: "/repo/\(SlashCommandMemory.capacity)").isEmpty == false)
        #expect(SlashCommandMemory(defaults: defaults).entries.count == SlashCommandMemory.capacity)
    }

    /// Eviction is by last report, so a directory reported in again outlives
    /// the ones that have gone quiet.
    @Test func reportingAgainKeepsADirectoryFromBeingEvicted() {
        let memory = SlashCommandMemory(defaults: makeDefaults())
        memory.remember([command("compact")], inDirectory: "/repo/0")
        for index in 1..<SlashCommandMemory.capacity {
            memory.remember([command("compact")], inDirectory: "/repo/\(index)")
        }

        memory.remember([command("compact"), command("deploy")], inDirectory: "/repo/0")
        memory.remember([command("compact")], inDirectory: "/repo/new")

        #expect(memory.commands(inDirectory: "/repo/0").map(\.name) == ["compact", "deploy"])
        #expect(memory.commands(inDirectory: "/repo/1").isEmpty)
    }

    @Test func forgettingClearsBothMemoryAndStorage() {
        let defaults = makeDefaults()
        let memory = SlashCommandMemory(defaults: defaults)
        memory.remember([command("compact")], inDirectory: "/repo")

        memory.forget()

        #expect(memory.entries.isEmpty)
        #expect(SlashCommandMemory(defaults: defaults).entries.isEmpty)
    }

    /// The pre-directory list recorded no directory, so it is dropped rather
    /// than filed under a guess.
    @Test func theOldGlobalListIsDropped() {
        let defaults = makeDefaults()
        defaults.set(Data("[]".utf8), forKey: "rememberedSlashCommands")

        _ = SlashCommandMemory(defaults: defaults)

        #expect(defaults.data(forKey: "rememberedSlashCommands") == nil)
    }
}
