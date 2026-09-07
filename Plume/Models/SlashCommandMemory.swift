import Foundation
import Observation

/// The slash commands the CLI last reported, so a tab with no session yet can
/// still autocomplete them.
///
/// The list describes the CLI installation rather than a conversation, and it
/// only arrives in the `initialize` reply — which cannot land before the
/// process starts. Starting a process to populate a menu is the wrong trade
/// for a tab the user may never send from, so the composer shows the
/// remembered list until a session reports for real and then replaces it.
///
/// Rewritten on every `initialize` rather than cached once, so adding or
/// removing a project command corrects the list rather than leaving a stale
/// one behind forever.
@MainActor
@Observable
final class SlashCommandMemory {
    static let shared = SlashCommandMemory()

    private(set) var commands: [SlashCommand] = []

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let key = "rememberedSlashCommands"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        commands = Self.decode(defaults.data(forKey: key))
    }

    /// An empty list means the reply carried no `commands` at all, which says
    /// nothing about the installation, so the remembered list survives it.
    /// Plume's own commands never enter: they need no session to be listed and
    /// would come back as CLI commands on the next launch.
    func remember(_ reported: [SlashCommand]) {
        let cliProvided = reported.filter { !$0.isPlumeProvided }
        guard !cliProvided.isEmpty, cliProvided != commands else { return }
        commands = cliProvided
        guard let data = try? JSONEncoder().encode(cliProvided.map(Stored.init)) else { return }
        defaults.set(data, forKey: key)
    }

    func forget() {
        commands = []
        defaults.removeObject(forKey: key)
    }

    private static func decode(_ data: Data?) -> [SlashCommand] {
        guard let data, let stored = try? JSONDecoder().decode([Stored].self, from: data) else { return [] }
        return stored.map(\.command)
    }

    /// `SlashCommand` stays the wire type; this is the persisted shape, which
    /// omits `isPlumeProvided` because nothing Plume-provided is ever stored.
    private struct Stored: Codable {
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
