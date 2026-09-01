import Foundation

struct GitError: LocalizedError {
    let command: String
    let status: Int32
    let stderr: String

    var errorDescription: String? {
        stderr.isEmpty ? "\(command) failed (exit \(status))" : stderr
    }
}

/// Runs `git` as a subprocess, surfacing stderr so failures can be shown.
enum GitRunner {
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
}

/// One entry from `git worktree list` — the repository's own checkout plus
/// every worktree added to it.
struct GitWorktree: Hashable, Sendable {
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
