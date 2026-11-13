import Foundation
import Testing

@testable import Plume

/// The slash-command list remembered per directory between sessions, which is
/// what a tab with no session yet autocompletes from.
@MainActor
struct SlashCommandMemoryTests {
    private let defaults = UserDefaults(suiteName: "SlashCommandMemoryTests.\(UUID().uuidString)")!
    private let file = FileManager.default.temporaryDirectory
        .appending(path: "SlashCommandMemoryTests-\(UUID().uuidString)")
        .appending(path: "slash-commands.json")

    private func makeMemory(removesLegacyKey: Bool = true, at file: URL? = nil) -> SlashCommandMemory {
        SlashCommandMemory(
            file: file ?? self.file, defaults: defaults, removesLegacyKey: removesLegacyKey, writeDelay: .zero
        )
    }

    private func loadedMemory(removesLegacyKey: Bool = true, at file: URL? = nil) async -> SlashCommandMemory {
        let memory = makeMemory(removesLegacyKey: removesLegacyKey, at: file)
        await memory.waitForLoad()
        return memory
    }

    private func storeLegacyList(_ names: [String], inDirectory directory: String) async throws {
        let scratch = FileManager.default.temporaryDirectory
            .appending(path: "SlashCommandMemoryTests-\(UUID().uuidString).json")
        let original = await loadedMemory(at: scratch)
        original.remember(names.map(command), inDirectory: directory)
        await original.waitForWrites()
        defaults.set(try Data(contentsOf: scratch), forKey: SlashCommandMemory.legacyKey)
    }

    private func command(_ name: String) -> SlashCommand {
        SlashCommand(name: name, description: "", argumentHint: "")
    }

    @Test func startsEmptyWithNothingRemembered() async {
        #expect(await loadedMemory().commands(inDirectory: "/repo").isEmpty)
    }

    @Test func aRememberedListSurvivesIntoTheNextLaunch() async {
        let memory = makeMemory()
        memory.remember([
            SlashCommand(name: "compact", description: "Compact the context", argumentHint: "[instructions]")
        ], inDirectory: "/repo")
        await memory.waitForWrites()

        let reloaded = await loadedMemory()
        #expect(reloaded.commands(inDirectory: "/repo") == [
            SlashCommand(name: "compact", description: "Compact the context", argumentHint: "[instructions]")
        ])
    }

    /// The bug this keying fixes: one project's project-scoped commands were
    /// offered in every other project.
    @Test func twoDirectoriesKeepSeparateLists() {
        let memory = makeMemory()
        memory.remember([command("compact"), command("deploy")], inDirectory: "/repo")
        memory.remember([command("compact"), command("migrate")], inDirectory: "/other")

        #expect(memory.commands(inDirectory: "/repo").map(\.name) == ["compact", "deploy"])
        #expect(memory.commands(inDirectory: "/other").map(\.name) == ["compact", "migrate"])
    }

    /// Nothing has reported there yet, which is the cold-start behaviour
    /// rather than a missing list.
    @Test func anUnknownDirectoryOffersNothing() {
        let memory = makeMemory()
        memory.remember([command("compact")], inDirectory: "/repo")

        #expect(memory.commands(inDirectory: "/elsewhere").isEmpty)
        #expect(memory.commands(inDirectory: nil).isEmpty)
    }

    /// Without a directory there is no key to file the list under, and
    /// guessing one is the bug.
    @Test func aReportWithNoDirectoryIsNotRemembered() {
        let memory = makeMemory()

        memory.remember([command("compact")], inDirectory: nil)

        #expect(memory.entries.isEmpty)
    }

    /// `initialize` reports on every launch, so a command the user has since
    /// deleted must not linger from the previous list.
    @Test func aLaterReportReplacesAStaleList() {
        let memory = makeMemory()
        memory.remember([command("compact"), command("deploy")], inDirectory: "/repo")

        memory.remember([command("compact")], inDirectory: "/repo")

        #expect(memory.commands(inDirectory: "/repo").map(\.name) == ["compact"])
    }

    /// An absent `commands` array says nothing about the installation, so it
    /// must not read as "this CLI has no commands".
    @Test func anEmptyReportKeepsWhatWasRemembered() {
        let memory = makeMemory()
        memory.remember([command("compact")], inDirectory: "/repo")

        memory.remember([], inDirectory: "/repo")

        #expect(memory.commands(inDirectory: "/repo").map(\.name) == ["compact"])
    }

    /// Plume's own commands are listed from `PlumeSlashCommand.all`, and
    /// storing them would make them come back as CLI commands.
    @Test func plumeProvidedCommandsAreNeverRemembered() {
        let memory = makeMemory()

        memory.remember(PlumeSlashCommand.all, inDirectory: "/repo")

        #expect(memory.commands(inDirectory: "/repo").isEmpty)
    }

    @Test func theOldestDirectoryFallsOffOnceTheListIsFull() async {
        let memory = makeMemory()
        for index in 0...SlashCommandMemory.capacity {
            memory.remember([command("compact")], inDirectory: "/repo/\(index)")
        }
        await memory.waitForWrites()

        #expect(memory.entries.count == SlashCommandMemory.capacity)
        #expect(memory.commands(inDirectory: "/repo/0").isEmpty)
        #expect(memory.commands(inDirectory: "/repo/\(SlashCommandMemory.capacity)").isEmpty == false)
        #expect(await loadedMemory().entries.count == SlashCommandMemory.capacity)
    }

    /// Eviction is by last report, so a directory reported in again outlives
    /// the ones that have gone quiet.
    @Test func reportingAgainKeepsADirectoryFromBeingEvicted() {
        let memory = makeMemory()
        memory.remember([command("compact")], inDirectory: "/repo/0")
        for index in 1..<SlashCommandMemory.capacity {
            memory.remember([command("compact")], inDirectory: "/repo/\(index)")
        }

        memory.remember([command("compact"), command("deploy")], inDirectory: "/repo/0")
        memory.remember([command("compact")], inDirectory: "/repo/new")

        #expect(memory.commands(inDirectory: "/repo/0").map(\.name) == ["compact", "deploy"])
        #expect(memory.commands(inDirectory: "/repo/1").isEmpty)
    }

    @Test func aListInUserDefaultsMovesToTheFileOnce() async throws {
        try await storeLegacyList(["compact"], inDirectory: "/repo")

        #expect(await loadedMemory().commands(inDirectory: "/repo").map(\.name) == ["compact"])
        #expect(defaults.data(forKey: SlashCommandMemory.legacyKey) == nil)
        #expect(await loadedMemory().commands(inDirectory: "/repo").map(\.name) == ["compact"])
    }

    @Test func aFlushBeforeTheLoadLandsStillRemovesTheLegacyList() async throws {
        try await storeLegacyList(["compact"], inDirectory: "/repo")
        let memory = makeMemory()

        memory.flush()
        await memory.waitForLoad()

        #expect(memory.commands(inDirectory: "/repo").map(\.name) == ["compact"])
        #expect(defaults.data(forKey: SlashCommandMemory.legacyKey) == nil)
    }

    /// Losing the key with nothing on disk would lose the list.
    @Test func aFailedMigrationKeepsTheLegacyList() async throws {
        try await storeLegacyList(["compact"], inDirectory: "/repo")
        let blocker = FileManager.default.temporaryDirectory
            .appending(path: "SlashCommandMemoryTests-\(UUID().uuidString)")
        try Data().write(to: blocker)
        let unwritable = blocker.appending(path: "slash-commands.json")

        let memory = await loadedMemory(at: unwritable)

        #expect(memory.commands(inDirectory: "/repo").map(\.name) == ["compact"])
        #expect(defaults.data(forKey: SlashCommandMemory.legacyKey) != nil)
    }

    /// Debug builds share one defaults domain across worktrees, so each one
    /// copies the list rather than taking it.
    @Test func aCopyingMigrationLeavesTheLegacyListForOtherBuilds() async throws {
        try await storeLegacyList(["compact"], inDirectory: "/repo")

        let memory = await loadedMemory(removesLegacyKey: false)

        #expect(memory.commands(inDirectory: "/repo").map(\.name) == ["compact"])
        #expect(defaults.data(forKey: SlashCommandMemory.legacyKey) != nil)
        #expect(await loadedMemory(removesLegacyKey: false).commands(inDirectory: "/repo").map(\.name) == ["compact"])
    }

    @Test func aLoadFindingTheFileAndTheLegacyKeyRemovesTheKey() async throws {
        let original = await loadedMemory()
        original.remember([command("compact")], inDirectory: "/repo")
        await original.waitForWrites()
        defaults.set(try Data(contentsOf: file), forKey: SlashCommandMemory.legacyKey)

        let memory = await loadedMemory()

        #expect(memory.commands(inDirectory: "/repo").map(\.name) == ["compact"])
        #expect(defaults.data(forKey: SlashCommandMemory.legacyKey) == nil)
    }

    /// A session can report before the file has loaded; its list is newer
    /// than the file's for that directory, and the rest of the file survives.
    @Test func aReportBeforeTheLoadMergesWithTheFile() async {
        let original = await loadedMemory()
        original.remember([command("compact"), command("deploy")], inDirectory: "/repo")
        original.remember([command("compact")], inDirectory: "/other")
        await original.waitForWrites()

        let memory = makeMemory()
        memory.remember([command("migrate")], inDirectory: "/repo")
        await memory.waitForWrites()

        #expect(memory.entries.map(\.directory) == ["/repo", "/other"])
        #expect(memory.commands(inDirectory: "/repo").map(\.name) == ["migrate"])
        #expect(await loadedMemory().entries.map(\.directory) == ["/repo", "/other"])
    }

    @Test func reportsInQuickSuccessionWriteOnce() async {
        let memory = await loadedMemory()

        memory.remember([command("compact")], inDirectory: "/a")
        memory.remember([command("compact")], inDirectory: "/b")
        memory.remember([command("compact")], inDirectory: "/c")
        await memory.waitForWrites()

        #expect(memory.diskWrites == 1)
        #expect(await loadedMemory().entries.map(\.directory) == ["/c", "/b", "/a"])
    }

    @Test func flushWritesWhatIsPending() async {
        let memory = SlashCommandMemory(file: file, defaults: defaults, writeDelay: .seconds(60))
        await memory.waitForLoad()
        memory.remember([command("compact")], inDirectory: "/repo")

        memory.flush()

        #expect(await loadedMemory().commands(inDirectory: "/repo").map(\.name) == ["compact"])
    }

    /// The pre-directory list recorded no directory, so it is dropped rather
    /// than filed under a guess.
    @Test func theOldGlobalListIsDropped() async {
        defaults.set(Data("[]".utf8), forKey: "rememberedSlashCommands")

        _ = await loadedMemory()

        #expect(defaults.data(forKey: "rememberedSlashCommands") == nil)
    }
}
