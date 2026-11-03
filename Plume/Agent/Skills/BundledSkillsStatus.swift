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
        var id: String { skill.name }
    }

    /// Empty until the first read lands.
    private(set) var entries: [Entry] = []
    private(set) var isChanging = false
    private(set) var lastError: String?

    private let directory: URL
    private let resources: URL?
    @ObservationIgnored private var activationObserver: NSObjectProtocol?

    init(directory: URL = BundledSkills.skillsDirectory, resources: URL? = Bundle.main.resourceURL) {
        self.directory = directory
        self.resources = resources
    }

    /// Plume owns none of its skills and the user hasn't said not now. A
    /// name another skill already holds doesn't count as installed.
    var needsInstallPrompt: Bool {
        !AppSettings.shared.bundledSkillsPromptDismissed
            && entries.contains { $0.state == .notInstalled }
            && !entries.contains { $0.state.isPlumeOwned }
    }

    var outdatedCount: Int {
        entries.count { $0.state == .outdated }
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
        let directory = directory, resources = resources
        Task {
            entries = await Task.detached { Self.read(directory: directory, resources: resources) }.value
        }
    }

    func installMissing() {
        change { skills, directory in
            for skill in skills where BundledSkills.state(of: skill, in: directory) == .notInstalled {
                try BundledSkills.install(skill, in: directory)
            }
        }
    }

    func install(_ skill: BundledSkill, replacing: Bool = false) {
        change { _, directory in try BundledSkills.install(skill, in: directory, replacing: replacing) }
    }

    func refreshOutdated() {
        change { skills, directory in try BundledSkills.refreshOutdated(skills, in: directory) }
    }

    func uninstall(_ skill: BundledSkill) {
        change { _, directory in try BundledSkills.uninstall(skill, in: directory) }
    }

    private func change(_ body: @escaping @Sendable ([BundledSkill], URL) throws -> Void) {
        guard !isChanging else { return }
        isChanging = true
        lastError = nil
        let directory = directory, resources = resources
        Task {
            let (error, entries) = await Task.detached { () -> (String?, [Entry]) in
                var message: String?
                do {
                    try body(BundledSkills.bundled(in: resources), directory)
                } catch {
                    message = error.localizedDescription
                }
                return (message, Self.read(directory: directory, resources: resources))
            }.value
            lastError = error
            self.entries = entries
            isChanging = false
        }
    }

    private nonisolated static func read(directory: URL, resources: URL?) -> [Entry] {
        BundledSkills.bundled(in: resources).map {
            Entry(skill: $0, state: BundledSkills.state(of: $0, in: directory))
        }
    }
}
