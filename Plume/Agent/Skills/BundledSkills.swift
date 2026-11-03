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
        guard type == .typeDirectory,
              let manifestData = try? Data(contentsOf: folder.appending(path: manifestFileName)),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: manifestData)
        else { return .ownedByOther }
        guard let installed = try? Data(contentsOf: folder.appending(path: skillFileName)),
              hash(of: installed) == manifest.hash
        else { return .modified }
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        guard Set(contents).subtracting([skillFileName, manifestFileName, ".DS_Store"]).isEmpty else { return .modified }
        guard manifest.hash != skill.hash else { return .installed }
        return isOlder(manifest.plumeBuild, than: runningBuild) ? .outdated : .installed
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
        let staging = directory.appending(path: ".\(skill.name).staging-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: staging) }
        try manager.createDirectory(at: staging, withIntermediateDirectories: false)
        try manager.copyItem(at: skill.url, to: staging.appending(path: skillFileName))
        let manifest = Manifest(hash: skill.hash, plumeBuild: plumeBuild)
        try JSONEncoder().encode(manifest).write(to: staging.appending(path: manifestFileName))

        if state == .outdated {
            _ = try manager.replaceItemAt(folder, withItemAt: staging)
        } else {
            try manager.moveItem(at: staging, to: folder)
        }
    }

    static func moveToTrash(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    /// Installs every skill with nothing at its name. Tries every one, then
    /// throws the first failure.
    static func installMissing(_ skills: [BundledSkill], in directory: URL = skillsDirectory) throws {
        try apply(skills, in: directory, plumeBuild: plumeBuild, to: .notInstalled)
    }

    /// Updates only the skills Plume owns and nobody has edited. Tries every
    /// one, then throws the first failure.
    static func refreshOutdated(
        _ skills: [BundledSkill],
        in directory: URL = skillsDirectory,
        plumeBuild: String = BundledSkills.plumeBuild
    ) throws {
        try apply(skills, in: directory, plumeBuild: plumeBuild, to: .outdated)
    }

    private static func apply(
        _ skills: [BundledSkill],
        in directory: URL,
        plumeBuild: String,
        to target: State
    ) throws {
        var firstError: Error?
        for skill in skills {
            let state = state(of: skill, in: directory, runningBuild: plumeBuild)
            guard state == target else { continue }
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
