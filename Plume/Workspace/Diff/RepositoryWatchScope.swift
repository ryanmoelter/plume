import Foundation

/// The directories a review watches, and which of their changes can alter it.
///
/// A linked worktree keeps its index and `HEAD` in `<common>/worktrees/<name>`
/// and its refs in the common directory, neither of them under its root, so
/// all three are watched. Paths are real paths, which is what FSEvents
/// reports.
nonisolated struct RepositoryWatchScope: Hashable, Sendable {
    let root: String
    let gitDirectory: String
    let commonDirectory: String

    enum Change: Hashable, Sendable {
        /// A file under the root, relative to it.
        case workingTree(String)
        /// Which files are tracked may have changed.
        case index
        /// `HEAD`, `packed-refs` or a ref under `refs/`, by its name there.
        case ref(String)
        case irrelevant
    }

    /// Every directory not already inside another.
    var watchedPaths: [String] {
        let candidates = [root, gitDirectory, commonDirectory]
        var paths: [String] = []
        for (index, path) in candidates.enumerated() where !paths.contains(path) {
            let isNested = candidates.enumerated().contains { other in
                other.offset != index && other.element != path && Self.relative(path, to: other.element) != nil
            }
            if !isNested { paths.append(path) }
        }
        return paths
    }

    static func resolve(in directory: String) throws -> RepositoryWatchScope {
        let output = try GitRunner.run(
            ["rev-parse", "--path-format=absolute", "--show-toplevel", "--absolute-git-dir", "--git-common-dir"],
            in: directory
        )
        let lines = output.split(separator: "\n").map(String.init)
        guard lines.count == 3 else {
            throw GitError(command: "git rev-parse", status: 0, stderr: "Unexpected output: \(output)")
        }
        return RepositoryWatchScope(
            root: realPath(lines[0]),
            gitDirectory: realPath(lines[1]),
            commonDirectory: realPath(lines[2])
        )
    }

    func classify(_ path: String) -> Change {
        if let relative = Self.relative(path, to: gitDirectory) {
            if relative == "index" { return .index }
            return relative == "HEAD" || Self.isRef(relative) ? .ref(relative) : .irrelevant
        }
        // The common directory's own index and `HEAD` belong to the main
        // checkout, not to a linked worktree.
        if let relative = Self.relative(path, to: commonDirectory) {
            return Self.isRef(relative) ? .ref(relative) : .irrelevant
        }
        guard let relative = Self.relative(path, to: root), !relative.isEmpty else { return .irrelevant }
        // Another repository's internals, such as a nested checkout's.
        if relative.split(separator: "/").contains(".git") { return .irrelevant }
        return .workingTree(relative)
    }

    private static func isRef(_ relative: String) -> Bool {
        relative == "packed-refs" || relative.hasPrefix("refs/")
    }

    private static func relative(_ path: String, to directory: String) -> String? {
        if path == directory { return "" }
        let prefix = directory.hasSuffix("/") ? directory : directory + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : nil
    }

    /// `realpath(3)`, since `URL.resolvingSymlinksInPath` drops `/private`
    /// and FSEvents keeps it.
    static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
