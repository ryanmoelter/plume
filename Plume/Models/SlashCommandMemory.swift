import Foundation
import Observation
import os

/// The slash commands the CLI last reported in each directory, so a tab with
/// no session yet can still autocomplete them.
///
/// The list describes the CLI installation *plus* whatever project commands
/// that directory carries, and it only arrives in the `initialize` reply —
/// which cannot land before the process starts. Starting a process to
/// populate a menu is the wrong trade for a tab the user may never send from,
/// so the composer shows the remembered list until a session reports for real
/// and then replaces it.
///
/// Keyed by directory because the reply does not mark which entries are
/// project-scoped: one global list offers one project's commands in every
/// other project, and there is no way to tell them apart after the fact.
/// A directory nothing has reported in yet offers nothing, which is the
/// cold-start behaviour.
///
/// Rewritten on every `initialize` rather than cached once, so adding or
/// removing a project command corrects the list rather than leaving a stale
/// one behind forever.
@MainActor
@Observable
final class SlashCommandMemory {
    /// The test host is the Debug app, so without a scratch file and defaults
    /// a test would migrate and overwrite the Debug build's own list.
    static let shared: SlashCommandMemory = {
        guard NSClassFromString("XCTestCase") == nil else {
            return SlashCommandMemory(
                file: FileManager.default.temporaryDirectory
                    .appending(path: "SlashCommandMemory-\(UUID().uuidString).json"),
                defaults: UserDefaults(suiteName: "SlashCommandMemory.\(UUID().uuidString)")!
            )
        }
        return SlashCommandMemory()
    }()

    /// Most recently reported first. A path map would grow an entry per
    /// directory forever, including worktrees that are long gone, so the
    /// oldest report falls off the end once the list is full.
    private(set) var entries: [Entry] = []

    /// Enough for every repository and worktree in flight at once.
    static let capacity = 20

    static var defaultFile: URL {
        AppPaths.applicationSupport.appending(path: "slash-commands.json")
    }

    private static let legacyKey = "rememberedSlashCommandsByDirectory"

    @ObservationIgnored private let file: URL
    @ObservationIgnored private var lastWrite: Task<Void, Never>?

    /// A full list runs past a megabyte, so it lives in a file written off the
    /// main thread rather than in user defaults, where every write posts a
    /// change notification that AppKit answers on the main thread.
    init(file: URL = SlashCommandMemory.defaultFile, defaults: UserDefaults = .standard) {
        self.file = file
        if let data = try? Data(contentsOf: file) {
            entries = Self.decode(data)
        } else if let legacy = defaults.data(forKey: Self.legacyKey) {
            entries = Self.decode(legacy)
            Self.write(entries.map(Stored.init), to: file)
            defaults.removeObject(forKey: Self.legacyKey)
        }
        // The pre-directory list recorded no directory, and guessing one
        // reintroduces the bug: it would offer some project's commands
        // everywhere else. It costs one cold tab its autocomplete, once.
        defaults.removeObject(forKey: "rememberedSlashCommands")
    }

    func commands(inDirectory directory: String?) -> [SlashCommand] {
        guard let directory else { return [] }
        return entries.first { $0.directory == directory }?.commands ?? []
    }

    /// An empty list means the reply carried no `commands` at all, which says
    /// nothing about the installation, so the remembered list survives it.
    /// Plume's own commands never enter: they need no session to be listed and
    /// would come back as CLI commands on the next launch.
    func remember(_ reported: [SlashCommand], inDirectory directory: String?) {
        guard let directory else { return }
        let cliProvided = reported.filter { !$0.isPlumeProvided }
        guard !cliProvided.isEmpty else { return }
        let existing = entries.firstIndex { $0.directory == directory }
        if let existing, entries[existing].commands == cliProvided, existing == 0 { return }
        if let existing { entries.remove(at: existing) }
        entries.insert(Entry(directory: directory, commands: cliProvided), at: 0)
        entries = Array(entries.prefix(Self.capacity))
        save(entries.map(Stored.init))
    }

    func forget() {
        entries = []
        save(nil)
    }

    /// Writes land in the order they were asked for.
    func waitForWrites() async {
        await lastWrite?.value
    }

    /// A nil list removes the file.
    private func save(_ stored: [Stored]?) {
        let previous = lastWrite
        let file = file
        lastWrite = Task.detached(priority: .utility) {
            await previous?.value
            if let stored {
                Self.write(stored, to: file)
            } else {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    private nonisolated static func write(_ stored: [Stored], to file: URL) {
        do {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try JSONEncoder().encode(stored).write(to: file, options: .atomic)
        } catch {
            Log.app.error("Could not write the remembered slash commands: \(error, privacy: .public)")
        }
    }

    private static func decode(_ data: Data) -> [Entry] {
        guard let stored = try? JSONDecoder().decode([Stored].self, from: data) else { return [] }
        return stored.prefix(capacity).map(\.entry)
    }

    struct Entry: Equatable {
        let directory: String
        let commands: [SlashCommand]
    }

    /// `SlashCommand` stays the wire type; this is the persisted shape, which
    /// omits `isPlumeProvided` because nothing Plume-provided is ever stored.
    private nonisolated struct Stored: Codable, Sendable {
        let directory: String
        let commands: [StoredCommand]

        init(_ entry: Entry) {
            directory = entry.directory
            commands = entry.commands.map(StoredCommand.init)
        }

        var entry: Entry {
            Entry(directory: directory, commands: commands.map(\.command))
        }
    }

    private nonisolated struct StoredCommand: Codable, Sendable {
        let name: String
        let description: String
        let argumentHint: String

        init(_ command: SlashCommand) {
            name = command.name
            description = command.description
            argumentHint = command.argumentHint
        }

        var command: SlashCommand {
            SlashCommand(name: name, description: description, argumentHint: argumentHint)
        }
    }
}
