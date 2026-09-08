import Foundation
import Observation

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
    static let shared = SlashCommandMemory()

    /// Most recently reported first. A path map would grow an entry per
    /// directory forever, including worktrees that are long gone, so the
    /// oldest report falls off the end once the list is full.
    private(set) var entries: [Entry] = []

    /// Enough for every repository and worktree in flight at once, and small
    /// enough that the whole list stays a cheap `UserDefaults` blob.
    static let capacity = 20

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let key = "rememberedSlashCommandsByDirectory"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        entries = Self.decode(defaults.data(forKey: key))
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
        guard let data = try? JSONEncoder().encode(entries.map(Stored.init)) else { return }
        defaults.set(data, forKey: key)
    }

    func forget() {
        entries = []
        defaults.removeObject(forKey: key)
    }

    private static func decode(_ data: Data?) -> [Entry] {
        guard let data, let stored = try? JSONDecoder().decode([Stored].self, from: data) else { return [] }
        return stored.prefix(capacity).map(\.entry)
    }

    struct Entry: Equatable {
        let directory: String
        let commands: [SlashCommand]
    }

    /// `SlashCommand` stays the wire type; this is the persisted shape, which
    /// omits `isPlumeProvided` because nothing Plume-provided is ever stored.
    private struct Stored: Codable {
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

    private struct StoredCommand: Codable {
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
