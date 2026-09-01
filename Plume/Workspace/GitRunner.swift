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
