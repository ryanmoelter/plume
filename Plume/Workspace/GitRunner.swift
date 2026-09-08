import Foundation

nonisolated struct GitError: LocalizedError {
    let command: String
    let status: Int32
    let stderr: String

    var errorDescription: String? {
        stderr.isEmpty ? "\(command) failed (exit \(status))" : stderr
    }
}

/// Runs `git` as a subprocess, surfacing stderr so failures can be shown.
///
/// Every call blocks its thread until `git` exits. Reach it through
/// `GitService`, never directly — the actor is what keeps that wait off the
/// main thread. Tests call it synchronously, which is fine; they have no
/// window to freeze.
nonisolated enum GitRunner {
    @discardableResult
    static func run(_ arguments: [String], in directory: String? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        if let directory {
            process.currentDirectoryURL = URL(fileURLWithPath: directory)
        }

        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error

        try process.run()
        // Read before waiting: a pipe that fills up would deadlock the child.
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = error.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let stdout = String(decoding: outputData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard process.terminationStatus == 0 else {
            throw GitError(
                command: "git " + arguments.joined(separator: " "),
                status: process.terminationStatus,
                stderr: String(decoding: errorData, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return stdout
    }

    /// Absolute path of the repository containing `path`, or nil if untracked.
    static func repositoryRoot(containing path: String) -> String? {
        try? run(["rev-parse", "--show-toplevel"], in: path)
    }

    static func currentBranch(in repository: String) -> String? {
        try? run(["rev-parse", "--abbrev-ref", "HEAD"], in: repository)
    }

    /// The directory git actually writes refs and the index to. In a linked
    /// worktree that is `<repository>/.git/worktrees/<name>`, not the
    /// worktree's own `.git`, which is a pointer file nothing ever rewrites.
    static func gitDirectory(containing path: String) -> String? {
        try? run(["rev-parse", "--absolute-git-dir"], in: path)
    }
}

/// One entry from `git worktree list` — the repository's own checkout plus
/// every worktree added to it.
/// Which project a checkout belongs to, and whether it is a linked worktree
/// of it.
///
/// The sidebar labels a row with the project rather than the folder: several
/// worktrees of one repository all live in differently-named directories, and
/// showing those names says nothing about which project the task is in.
nonisolated struct CheckoutFacts: Sendable, Equatable {
    /// The original clone's working directory — the same value for every
    /// worktree of a repository.
    let projectRoot: String
    /// This checkout's own directory.
    let checkoutRoot: String

    var isWorktree: Bool { projectRoot != checkoutRoot }

    var projectName: String? {
        let name = URL(fileURLWithPath: projectRoot).lastPathComponent
        return name.isEmpty ? nil : name
    }

    /// Parses `rev-parse --path-format=absolute --git-common-dir --show-toplevel`.
    ///
    /// `--git-common-dir` is the original clone's `.git` from inside any
    /// worktree, which is what makes one call answer both questions. A bare
    /// repository has no toplevel and yields nothing.
    static func parsing(_ output: String) -> CheckoutFacts? {
        let lines = output.split(separator: "\n").map(String.init)
        guard lines.count >= 2 else { return nil }
        let commonDirectory = URL(fileURLWithPath: lines[0]).standardizedFileURL
        let checkoutRoot = URL(fileURLWithPath: lines[1]).standardizedFileURL
        return CheckoutFacts(
            projectRoot: commonDirectory.deletingLastPathComponent().path,
            checkoutRoot: checkoutRoot.path
        )
    }
}

extension GitRunner {
    static func checkoutFacts(containing path: String) -> CheckoutFacts? {
        guard let output = try? run(
            ["rev-parse", "--path-format=absolute", "--git-common-dir", "--show-toplevel"],
            in: path
        ) else { return nil }
        return CheckoutFacts.parsing(output)
    }
}

nonisolated struct GitWorktree: Hashable, Sendable {
    let path: String
    /// nil when the worktree has a detached HEAD.
    let branch: String?
    /// The repository's own checkout, which `git` always lists first.
    let isMain: Bool
}

extension GitRunner {
    static func worktrees(in repository: String) -> [GitWorktree] {
        guard let output = try? run(["worktree", "list", "--porcelain"], in: repository) else {
            return []
        }
        return output.components(separatedBy: "\n\n").enumerated().compactMap { index, record in
            var path: String?
            var branch: String?
            for line in record.split(separator: "\n") {
                if let value = line.dropPrefix("worktree ") {
                    path = value
                } else if let value = line.dropPrefix("branch refs/heads/") {
                    branch = value
                }
            }
            guard let path else { return nil }
            return GitWorktree(path: path, branch: branch, isMain: index == 0)
        }
    }
}

private extension Substring {
    func dropPrefix(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}

/// What a repository's forge column needs to know about the repository
/// itself, as opposed to any one branch.
nonisolated struct RepositoryFacts: Sendable, Equatable {
    let originURL: String?
    /// The branch `origin/HEAD` points at, which is the trunk no row should
    /// show a pull request for.
    let defaultBranch: String?
}

extension GitRunner {
    static func originURL(in repository: String) -> String? {
        try? run(["remote", "get-url", "origin"], in: repository)
    }

    /// `origin/HEAD` is only set once someone has fetched or cloned with it,
    /// so a repository that never got one falls back to whichever of
    /// `main`/`master` exists as a remote branch.
    static func defaultBranch(in repository: String) -> String? {
        if let ref = try? run(["symbolic-ref", "--short", "refs/remotes/origin/HEAD"], in: repository),
           let name = ref.split(separator: "/").last, !name.isEmpty {
            return String(name)
        }
        for candidate in ["main", "master"] {
            if (try? run(["rev-parse", "--verify", "--quiet", "refs/remotes/origin/\(candidate)"], in: repository)) != nil {
                return candidate
            }
        }
        return nil
    }

    static func repositoryFacts(in repository: String) -> RepositoryFacts {
        RepositoryFacts(originURL: originURL(in: repository), defaultBranch: defaultBranch(in: repository))
    }
}
