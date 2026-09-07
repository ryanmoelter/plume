import Foundation
import Testing

@testable import Plume

/// The slash-command list remembered between sessions, which is what a tab
/// with no session yet autocompletes from.
@MainActor
struct SlashCommandMemoryTests {
    private func makeDefaults() -> UserDefaults {
        let defaults = UserDefaults(suiteName: "SlashCommandMemoryTests.\(UUID().uuidString)")!
        defaults.removePersistentDomain(forName: defaults.description)
        return defaults
    }

    @Test func startsEmptyWithNothingRemembered() {
        #expect(SlashCommandMemory(defaults: makeDefaults()).commands.isEmpty)
    }

    @Test func aRememberedListSurvivesIntoTheNextLaunch() {
        let defaults = makeDefaults()
        SlashCommandMemory(defaults: defaults).remember([
            SlashCommand(name: "compact", description: "Compact the context", argumentHint: "[instructions]")
        ])

        let reloaded = SlashCommandMemory(defaults: defaults)
        #expect(reloaded.commands == [
            SlashCommand(name: "compact", description: "Compact the context", argumentHint: "[instructions]")
        ])
    }

    /// `initialize` reports on every launch, so a command the user has since
    /// deleted must not linger from the previous list.
    @Test func aLaterReportReplacesAStaleList() {
        let memory = SlashCommandMemory(defaults: makeDefaults())
        memory.remember([
            SlashCommand(name: "compact", description: "", argumentHint: ""),
            SlashCommand(name: "deploy", description: "A project command", argumentHint: ""),
        ])

        memory.remember([SlashCommand(name: "compact", description: "", argumentHint: "")])

        #expect(memory.commands.map(\.name) == ["compact"])
    }

    /// An absent `commands` array says nothing about the installation, so it
    /// must not read as "this CLI has no commands".
    @Test func anEmptyReportKeepsWhatWasRemembered() {
        let memory = SlashCommandMemory(defaults: makeDefaults())
        memory.remember([SlashCommand(name: "compact", description: "", argumentHint: "")])

        memory.remember([])

        #expect(memory.commands.map(\.name) == ["compact"])
    }

    /// Plume's own commands are listed from `PlumeSlashCommand.all`, and
    /// storing them would make them come back as CLI commands.
    @Test func plumeProvidedCommandsAreNeverRemembered() {
        let memory = SlashCommandMemory(defaults: makeDefaults())

        memory.remember(PlumeSlashCommand.all)

        #expect(memory.commands.isEmpty)
    }

    @Test func forgettingClearsBothMemoryAndStorage() {
        let defaults = makeDefaults()
        let memory = SlashCommandMemory(defaults: defaults)
        memory.remember([SlashCommand(name: "compact", description: "", argumentHint: "")])

        memory.forget()

        #expect(memory.commands.isEmpty)
        #expect(SlashCommandMemory(defaults: defaults).commands.isEmpty)
    }
}
