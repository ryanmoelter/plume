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
/// Copies rather than symlinks, so a skill outlives the bundle it came from;
/// the manifest's hash is what tells an older copy from a newer bundle. A
/// folder without a manifest, or with a `SKILL.md` that no longer matches
/// it, is someone else's, and only an explicit replace touches it.
nonisolated enum BundledSkills {
    /// Resources flatten into one folder, so each skill is a uniquely named
    /// file rather than a `SKILL.md` in a folder of its own.
    static let fileSuffix = ".skill.md"
    static let skillFileName = "SKILL.md"
    static let manifestFileName = ".plume-skill.json"

    static var skillsDirectory: URL {
        URL.homeDirectory.appending(path: ".claude/skills")
    }

    static var plumeVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    struct Manifest: Codable, Equatable {
        var hash: String
        var plumeVersion: String
    }

    enum State: Equatable, Sendable {
        case notInstalled
        case installed
        /// Plume's copy, from a different bundle than this one.
        case outdated
        /// Something at the name that Plume didn't write: a folder or file
        /// without a manifest, or a symlink.
        case ownedByOther
        /// Plume's copy, edited since.
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

    static func state(of skill: BundledSkill, in directory: URL = skillsDirectory) -> State {
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
        return manifest.hash == skill.hash ? .installed : .outdated
    }

    /// Writes the skill and its manifest into place together. Refuses a
    /// folder Plume doesn't own unless `replacing`, which trashes it first,
    /// a symlink as the link itself.
    static func install(
        _ skill: BundledSkill,
        in directory: URL = skillsDirectory,
        replacing: Bool = false,
        plumeVersion: String = BundledSkills.plumeVersion,
        trash: (URL) throws -> Void = moveToTrash
    ) throws {
        let manager = FileManager.default
        let folder = directory.appending(path: skill.name)
        let state = state(of: skill, in: directory)
        switch state {
        case .installed:
            return
        case .ownedByOther, .modified:
            guard replacing else { throw InstallError.notOwned(folder) }
            try trash(folder)
        case .notInstalled, .outdated:
            break
        }

        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let staging = try manager.url(
            for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: directory, create: true
        )
        defer { try? manager.removeItem(at: staging) }
        let staged = staging.appending(path: skill.name)
        try manager.createDirectory(at: staged, withIntermediateDirectories: false)
        try manager.copyItem(at: skill.url, to: staged.appending(path: skillFileName))
        let manifest = Manifest(hash: skill.hash, plumeVersion: plumeVersion)
        try JSONEncoder().encode(manifest).write(to: staged.appending(path: manifestFileName))

        if state == .outdated {
            _ = try manager.replaceItemAt(folder, withItemAt: staged)
        } else {
            try manager.moveItem(at: staged, to: folder)
        }
    }

    static func moveToTrash(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    /// Updates only the skills Plume owns and nobody has edited. Tries every
    /// one, then throws the first failure.
    static func refreshOutdated(_ skills: [BundledSkill], in directory: URL = skillsDirectory) throws {
        var firstError: Error?
        for skill in skills where state(of: skill, in: directory) == .outdated {
            do {
                try install(skill, in: directory)
            } catch {
                firstError = firstError ?? error
            }
        }
        if let firstError { throw firstError }
    }

    /// Removes Plume's unedited copy. Anything else at the name stays.
    static func uninstall(_ skill: BundledSkill, in directory: URL = skillsDirectory) throws {
        switch state(of: skill, in: directory) {
        case .installed, .outdated:
            try FileManager.default.removeItem(at: directory.appending(path: skill.name))
        case .notInstalled, .ownedByOther, .modified:
            return
        }
    }
}
