import AppKit
import Foundation
import Observation

/// What Home, the sidebar footer and Settings show about the bundled skills.
/// Every read and write of the skills directory runs off the main actor.
@MainActor
@Observable
final class BundledSkillsStatus {
    static let shared = BundledSkillsStatus()

    nonisolated struct Entry: Identifiable, Equatable, Sendable {
        let skill: BundledSkill
        let state: BundledSkills.State
        let isSymlink: Bool
        var id: String { skill.name }
    }

    nonisolated struct Snapshot: Equatable, Sendable {
        var entries: [Entry] = []
        /// Unedited copies of skills Plume no longer bundles.
        var retired: [URL] = []
    }

    /// Empty until the first read lands.
    private var snapshot = Snapshot()
    var entries: [Entry] { snapshot.entries }
    private(set) var isChanging = false

    enum Surface: Hashable {
        case home, sidebar, settings
    }

    private var errors: [Surface: String] = [:]

    let directory: URL
    /// Nil loads `BundledSkills.all` on first use, off the main actor.
    private let skills: [BundledSkill]?
    /// Bumped by every read and change, so a read that began before a change
    /// finished can't overwrite its result.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var activationObserver: NSObjectProtocol?

    init(directory: URL = BundledSkills.skillsDirectory, skills: [BundledSkill]? = nil) {
        self.directory = directory
        self.skills = skills
    }

    func error(for surface: Surface) -> String? {
        errors[surface]
    }

    func clearError(for surface: Surface) {
        errors[surface] = nil
    }

    /// Plume owns none of its skills and the user hasn't said not now. A
    /// name another skill already holds doesn't count as installed.
    var needsInstallPrompt: Bool {
        !AppSettings.shared.bundledSkillsPromptDismissed
            && entries.contains { $0.state == .notInstalled }
            && !entries.contains { $0.state.isPlumeOwned }
    }

    /// Outdated copies, skills a newer Plume added once Plume owns any, and
    /// retired copies to remove. A name someone else holds never counts.
    var pendingUpdateCount: Int {
        Self.pendingUpdateCount(of: snapshot)
    }

    nonisolated static func pendingUpdateCount(of snapshot: Snapshot) -> Int {
        let ownsAny = snapshot.entries.contains { $0.state.isPlumeOwned }
        let outdated = snapshot.entries.count { $0.state == .outdated }
        let added = ownsAny ? snapshot.entries.count { $0.state == .notInstalled } : 0
        return outdated + added + snapshot.retired.count
    }

    /// Reads now and again whenever the app becomes active, since the user
    /// may have changed the skills directory by hand.
    func start() {
        guard activationObserver == nil else { return }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    func refresh() {
        generation += 1
        let started = generation
        let directory = directory, skills = skills
        Task {
            let read = await Task.detached { Self.read(directory: directory, skills: skills ?? BundledSkills.all) }.value
            guard started == generation, read != snapshot else { return }
            snapshot = read
        }
    }

    func installMissing(on surface: Surface) {
        change(on: surface, marksInstalled: true) { skills, directory in
            try BundledSkills.installMissing(skills, in: directory)
        }
    }

    func install(_ skill: BundledSkill, replacing: Bool = false) {
        change(on: .settings, marksInstalled: true) { _, directory in
            try BundledSkills.install(skill, in: directory, replacing: replacing)
        }
    }

    func refreshPending() {
        change(on: .sidebar) { skills, directory in try BundledSkills.refreshPending(skills, in: directory) }
    }

    func uninstall(_ skill: BundledSkill) {
        change(on: .settings) { _, directory in try BundledSkills.uninstall(skill, in: directory) }
    }

    /// A successful install ends Home's offer for good, even if the user
    /// later removes every skill.
    private func change(
        on surface: Surface,
        marksInstalled: Bool = false,
        _ body: @escaping @Sendable ([BundledSkill], URL) throws -> Void
    ) {
        guard !isChanging else { return }
        isChanging = true
        errors[surface] = nil
        generation += 1
        let directory = directory, skills = skills
        Task {
            let (error, read) = await Task.detached { () -> (String?, Snapshot) in
                let skills = skills ?? BundledSkills.all
                var message: String?
                do {
                    try body(skills, directory)
                } catch {
                    message = error.localizedDescription
                }
                return (message, Self.read(directory: directory, skills: skills))
            }.value
            generation += 1
            errors[surface] = error
            if error == nil, marksInstalled {
                AppSettings.shared.bundledSkillsPromptDismissed = true
            }
            if read != snapshot { snapshot = read }
            isChanging = false
        }
    }

    private nonisolated static func read(directory: URL, skills: [BundledSkill]) -> Snapshot {
        let entries = skills.map {
            Entry(
                skill: $0,
                state: BundledSkills.state(of: $0, in: directory),
                isSymlink: BundledSkills.isSymlink(directory.appending(path: $0.name))
            )
        }
        return Snapshot(entries: entries, retired: BundledSkills.retiredFolders(keeping: skills, in: directory))
    }
}
