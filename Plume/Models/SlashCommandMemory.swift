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
    ///
    /// Empty until the file has loaded, which happens off the main thread.
    private(set) var entries: [Entry] = []

    /// Enough for every repository and worktree in flight at once.
    nonisolated static let capacity = 20

    static var defaultFile: URL {
        AppPaths.applicationSupport.appending(path: "slash-commands.json")
    }

    static let legacyKey = "rememberedSlashCommandsByDirectory"

    /// Debug builds keep a file per worktree but share one defaults domain,
    /// so removing the key would hand the list to whichever worktree launched
    /// first and leave every other debug build without it.
    #if DEBUG
    static let migrationRemovesLegacyKey = false
    #else
    static let migrationRemovesLegacyKey = true
    #endif

    @ObservationIgnored private let file: URL
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let removesLegacyKey: Bool
    @ObservationIgnored private let writeDelay: Duration
    /// Serial, so the load and every write land on disk in order, and
    /// `flush()` can wait for them all.
    @ObservationIgnored private let disk = DispatchQueue(label: "SlashCommandMemory", qos: .utility)
    @ObservationIgnored private var loading: Task<Void, Never>?
    @ObservationIgnored private var isLoaded = false
    /// Set by `forget()` before the load lands, whose entries are then stale.
    @ObservationIgnored private var discardsLoad = false
    @ObservationIgnored private var isDirty = false
    @ObservationIgnored private var pendingWrite: Task<Void, Never>?
    @ObservationIgnored private(set) var diskWrites = 0

    /// A full list runs past a megabyte, so it lives in a file read and
    /// written off the main thread rather than in user defaults, where every
    /// write posts a change notification that AppKit answers on the main
    /// thread.
    init(
        file: URL = SlashCommandMemory.defaultFile,
        defaults: UserDefaults = .standard,
        removesLegacyKey: Bool = SlashCommandMemory.migrationRemovesLegacyKey,
        writeDelay: Duration = .milliseconds(500)
    ) {
        self.file = file
        self.defaults = defaults
        self.removesLegacyKey = removesLegacyKey
        self.writeDelay = writeDelay
        // The pre-directory list recorded no directory, and guessing one
        // reintroduces the bug: it would offer some project's commands
        // everywhere else. It costs one cold tab its autocomplete, once.
        defaults.removeObject(forKey: "rememberedSlashCommands")
        let legacy = defaults.data(forKey: Self.legacyKey)
        let disk = disk
        loading = Task { [weak self] in
            let loaded = await withCheckedContinuation { continuation in
                disk.async { continuation.resume(returning: Self.load(from: file, legacy: legacy)) }
            }
            self?.finishLoading(loaded)
        }
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
        scheduleWrite()
    }

    func forget() {
        entries = []
        if !isLoaded { discardsLoad = true }
        scheduleWrite()
    }

    func waitForLoad() async {
        await loading?.value
    }

    /// Waits for the pending write, if any, and everything queued before it.
    func waitForWrites() async {
        await loading?.value
        await pendingWrite?.value
        await withCheckedContinuation { continuation in disk.async { continuation.resume() } }
    }

    /// Writes any pending change now, blocking until it is on disk. For
    /// termination, when a delayed write would never run.
    func flush() {
        pendingWrite?.cancel()
        pendingWrite = nil
        if !isLoaded {
            let file = file
            let legacy = defaults.data(forKey: Self.legacyKey)
            finishLoading(disk.sync { Self.load(from: file, legacy: legacy) })
        }
        guard isDirty else {
            disk.sync {}
            return
        }
        isDirty = false
        diskWrites += 1
        let stored = snapshot()
        let file = file
        disk.sync { _ = Self.persist(stored, to: file) }
    }

    private func finishLoading(_ loaded: Loaded) {
        guard !isLoaded else { return }
        isLoaded = true
        if !discardsLoad {
            let reported = Set(entries.map(\.directory))
            let older = loaded.stored.map(\.entry).filter { !reported.contains($0.directory) }
            entries = Array((entries + older).prefix(Self.capacity))
        }
        if loaded.migrated, removesLegacyKey {
            defaults.removeObject(forKey: Self.legacyKey)
        }
    }

    /// Latest wins: one write is pending at a time, and it takes whatever the
    /// list holds when it runs.
    private func scheduleWrite() {
        isDirty = true
        guard pendingWrite == nil else { return }
        pendingWrite = Task { [weak self, writeDelay] in
            do { try await Task.sleep(for: writeDelay) } catch { return }
            await self?.writeIfDirty()
        }
    }

    private func writeIfDirty() async {
        // Writing before the load lands would replace the file with only
        // what was reported since launch.
        await loading?.value
        guard !Task.isCancelled else { return }
        pendingWrite = nil
        guard isDirty else { return }
        isDirty = false
        diskWrites += 1
        let stored = snapshot()
        let file = file
        await withCheckedContinuation { continuation in
            disk.async {
                _ = Self.persist(stored, to: file)
                continuation.resume()
            }
        }
    }

    /// Nil removes the file.
    private func snapshot() -> [Stored]? {
        entries.isEmpty ? nil : entries.map(Stored.init)
    }

    private nonisolated struct Loaded: Sendable {
        var stored: [Stored]
        /// The legacy list reached the file, so the key may go.
        var migrated: Bool
    }

    private nonisolated static func load(from file: URL, legacy: Data?) -> Loaded {
        if let data = try? Data(contentsOf: file) {
            return Loaded(stored: decode(data), migrated: false)
        }
        guard let legacy else { return Loaded(stored: [], migrated: false) }
        let stored = decode(legacy)
        return Loaded(stored: stored, migrated: persist(stored, to: file))
    }

    private nonisolated static func persist(_ stored: [Stored]?, to file: URL) -> Bool {
        guard let stored else {
            try? FileManager.default.removeItem(at: file)
            return true
        }
        return write(stored, to: file)
    }

    /// Returns whether the list reached the file.
    private nonisolated static func write(_ stored: [Stored], to file: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try JSONEncoder().encode(stored).write(to: file, options: .atomic)
            return true
        } catch {
            Log.app.error("Could not write the remembered slash commands: \(error, privacy: .public)")
            return false
        }
    }

    private nonisolated static func decode(_ data: Data) -> [Stored] {
        guard let stored = try? JSONDecoder().decode([Stored].self, from: data) else { return [] }
        return Array(stored.prefix(capacity))
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
