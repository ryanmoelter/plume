import CryptoKit
import Foundation

nonisolated struct BundledSkill: Hashable, Sendable {
    let name: String
    let url: URL
    /// SHA-256 of the bundled file, hex.
    let hash: String
}

/// Copies the skills Plume bundles into Claude Code's skills directory, as
/// `<name>/SKILL.md` beside a manifest that records what Plume wrote.
///
/// Copies rather than symlinks, so a skill outlives the bundle it came from.
/// The manifest's hash and Plume build tell an older copy from a newer one,
/// since every build shares the directory. A folder without a manifest, with
/// a `SKILL.md` that no longer matches it, or with extra files in it is
/// someone else's, and only an explicit replace touches it.
nonisolated enum BundledSkills {
    /// Resources flatten into one folder, so each skill is a uniquely named
    /// file rather than a `SKILL.md` in a folder of its own.
    static let fileSuffix = ".skill.md"
    static let skillFileName = "SKILL.md"
    static let manifestFileName = ".plume-skill.json"

    static var skillsDirectory: URL {
        URL.homeDirectory.appending(path: ".claude/skills")
    }

    static var plumeBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    /// Computed once, on first use: the bundle doesn't change while the app runs.
    /// The scan reads every file, so first use belongs off the main actor.
    static let all = bundled()

    struct Manifest: Codable, Equatable {
        var hash: String
        /// The `CFBundleVersion` of the build that wrote the copy.
        var plumeBuild: String?
    }

    enum State: Equatable, Sendable {
        case notInstalled
        case installed
        /// Plume's copy, from an older build than this one.
        case outdated
        /// Something at the name that Plume didn't write: a folder or file
        /// without a manifest, or a symlink.
        case ownedByOther
        /// Plume's copy, edited since or holding files Plume didn't write.
        case modified

        /// Only an explicit replace may write over it.
        var needsReplace: Bool {
            switch self {
            case .ownedByOther, .modified: true
            case .notInstalled, .installed, .outdated: false
            }
        }

        var isPlumeOwned: Bool {
            switch self {
            case .installed, .outdated, .modified: true
            case .notInstalled, .ownedByOther: false
            }
        }
    }

    enum InstallError: LocalizedError {
        case notOwned(URL)

        var errorDescription: String? {
            switch self {
            case .notOwned(let url): "\(url.path) isn't Plume's. Replace it to install Plume's skill."
            }
        }
    }

    /// Every `*.skill.md` in `resources`, by name.
    static func bundled(in resources: URL? = Bundle.main.resourceURL) -> [BundledSkill] {
        guard let resources,
              let urls = try? FileManager.default.contentsOfDirectory(at: resources, includingPropertiesForKeys: nil)
        else { return [] }
        return urls
            .filter { $0.lastPathComponent.hasSuffix(fileSuffix) }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                let name = String(url.lastPathComponent.dropLast(fileSuffix.count))
                return BundledSkill(name: name, url: url, hash: hash(of: data))
            }
            .sorted { $0.name < $1.name }
    }

    static func hash(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func state(
        of skill: BundledSkill,
        in directory: URL = skillsDirectory,
        runningBuild: String = BundledSkills.plumeBuild
    ) -> State {
        let folder = directory.appending(path: skill.name)
        // Not `fileExists`, which follows a symlink and reads a dangling one as absent.
        guard let type = try? FileManager.default.attributesOfItem(atPath: folder.path)[.type] as? FileAttributeType else {
            return .notInstalled
        }
        guard type == .typeDirectory else { return .ownedByOther }
        switch inspect(folder) {
        case .foreign: return .ownedByOther
        case .modified: return .modified
        case .unmodified(let manifest):
            guard manifest.hash != skill.hash else { return .installed }
            return isOlder(manifest.plumeBuild, than: runningBuild) ? .outdated : .installed
        }
    }

    private enum Inspection {
        case foreign
        case modified
        case unmodified(Manifest)
    }

    private static func inspect(_ folder: URL) -> Inspection {
        guard let manifestData = try? Data(contentsOf: folder.appending(path: manifestFileName)),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: manifestData)
        else { return .foreign }
        guard let installed = try? Data(contentsOf: folder.appending(path: skillFileName)),
              hash(of: installed) == manifest.hash
        else { return .modified }
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        guard Set(contents).subtracting([skillFileName, manifestFileName, ".DS_Store"]).isEmpty else { return .modified }
        return .unmodified(manifest)
    }

    /// Unedited copies an older build wrote for a skill this one no longer
    /// bundles. A copy from an equal or newer build may be a skill this build
    /// predates, so it stays.
    static func retiredFolders(
        keeping skills: [BundledSkill],
        in directory: URL = skillsDirectory,
        runningBuild: String = BundledSkills.plumeBuild
    ) -> [URL] {
        let names = Set(skills.map(\.name))
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey], options: .skipsHiddenFiles
        )) ?? []
        return folders.filter { folder in
            guard !names.contains(folder.lastPathComponent),
                  (try? folder.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
                  case .unmodified(let manifest) = inspect(folder)
            else { return false }
            return isOlder(manifest.plumeBuild, than: runningBuild)
        }
    }

    /// A missing or unparseable build counts as older.
    private static func isOlder(_ build: String?, than running: String) -> Bool {
        guard let build, let installed = Int(build) else { return true }
        return installed < (Int(running) ?? 0)
    }

    static func isSymlink(_ url: URL) -> Bool {
        let type = try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType
        return type == .typeSymbolicLink
    }

    /// Writes the skill and its manifest into place together. Refuses a
    /// folder Plume doesn't own unless `replacing`, which trashes a real
    /// folder first and deletes a symlink itself, never its target.
    static func install(
        _ skill: BundledSkill,
        in directory: URL = skillsDirectory,
        replacing: Bool = false,
        plumeBuild: String = BundledSkills.plumeBuild,
        trash: (URL) throws -> Void = moveToTrash
    ) throws {
        let state = state(of: skill, in: directory, runningBuild: plumeBuild)
        try install(skill, state: state, in: directory, replacing: replacing, plumeBuild: plumeBuild, trash: trash)
    }

    private static func install(
        _ skill: BundledSkill,
        state: State,
        in directory: URL,
        replacing: Bool = false,
        plumeBuild: String,
        trash: (URL) throws -> Void = moveToTrash
    ) throws {
        let manager = FileManager.default
        let folder = directory.appending(path: skill.name)
        switch state {
        case .installed:
            return
        case .ownedByOther, .modified:
            guard replacing else { throw InstallError.notOwned(folder) }
            if isSymlink(folder) {
                try manager.removeItem(at: folder)
            } else {
                try trash(folder)
            }
        case .notInstalled, .outdated:
            break
        }

        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let stagingRoot = try stagingDirectory(appropriateFor: directory)
        defer { try? manager.removeItem(at: stagingRoot) }
        let staging = stagingRoot.appending(path: skill.name)
        try manager.createDirectory(at: staging, withIntermediateDirectories: false)
        try manager.copyItem(at: skill.url, to: staging.appending(path: skillFileName))
        let manifest = Manifest(hash: skill.hash, plumeBuild: plumeBuild)
        try JSONEncoder().encode(manifest).write(to: staging.appending(path: manifestFileName))

        if state == .outdated {
            guard self.state(of: skill, in: directory, runningBuild: plumeBuild) == .outdated else { return }
            _ = try manager.replaceItemAt(folder, withItemAt: staging)
        } else {
            try manager.moveItem(at: staging, to: folder)
        }
    }

    /// A temporary directory on `directory`'s volume, so the move into place
    /// stays atomic and a crash leaves nothing in the skills directory.
    private static func stagingDirectory(appropriateFor directory: URL) throws -> URL {
        let manager = FileManager.default
        if let url = try? manager.url(
            for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: directory, create: true
        ) {
            return url
        }
        let url = manager.temporaryDirectory.appending(path: "plume-skill-staging-\(UUID().uuidString)")
        try manager.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    static func moveToTrash(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    /// Installs every skill with nothing at its name. Tries every one, then
    /// throws the first failure.
    static func installMissing(_ skills: [BundledSkill], in directory: URL = skillsDirectory) throws {
        try apply(skills, in: directory, plumeBuild: plumeBuild) { $0 == .notInstalled }
    }

    /// Updates the skills Plume owns and nobody has edited, adds the skills
    /// a newer build bundles once Plume owns any, and trashes unedited copies
    /// of retired skills. Tries every one, then throws the first failure.
    static func refreshPending(
        _ skills: [BundledSkill],
        in directory: URL = skillsDirectory,
        plumeBuild: String = BundledSkills.plumeBuild,
        trash: (URL) throws -> Void = moveToTrash
    ) throws {
        let ownsAny = skills.contains { state(of: $0, in: directory, runningBuild: plumeBuild).isPlumeOwned }
        var firstError: Error?
        do {
            try apply(skills, in: directory, plumeBuild: plumeBuild) { $0 == .outdated || ($0 == .notInstalled && ownsAny) }
        } catch {
            firstError = error
        }
        for folder in retiredFolders(keeping: skills, in: directory, runningBuild: plumeBuild) {
            do {
                try trash(folder)
            } catch {
                firstError = firstError ?? error
            }
        }
        if let firstError { throw firstError }
    }

    private static func apply(
        _ skills: [BundledSkill],
        in directory: URL,
        plumeBuild: String,
        where shouldInstall: (State) -> Bool
    ) throws {
        var firstError: Error?
        for skill in skills {
            let state = state(of: skill, in: directory, runningBuild: plumeBuild)
            guard shouldInstall(state) else { continue }
            do {
                try install(skill, state: state, in: directory, plumeBuild: plumeBuild)
            } catch {
                firstError = firstError ?? error
            }
        }
        if let firstError { throw firstError }
    }

    /// Trashes Plume's unedited copy. Anything else at the name stays.
    static func uninstall(
        _ skill: BundledSkill,
        in directory: URL = skillsDirectory,
        trash: (URL) throws -> Void = moveToTrash
    ) throws {
        switch state(of: skill, in: directory) {
        case .installed, .outdated:
            try trash(directory.appending(path: skill.name))
        case .notInstalled, .ownedByOther, .modified:
            return
        }
    }
}
