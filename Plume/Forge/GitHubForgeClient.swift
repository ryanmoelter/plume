import Foundation
import Synchronization

/// Fetches pull requests through the `gh` CLI.
///
/// An actor for the reason `GitService` is one: the subprocess blocks its
/// thread, and the project defaults isolation to `MainActor`, so reaching it
/// has to mean `await`.
actor GitHubForgeClient: ForgeClient {
    static let shared = GitHubForgeClient()

    private let timeout: Duration

    init(timeout: Duration = .seconds(20)) {
        self.timeout = timeout
    }

    func fetchPullRequests(
        forBranches branches: [String],
        in repository: String
    ) async throws -> [String: PullRequest?] {
        if branches.isEmpty { return [:] }
        var out: [String: PullRequest?] = [:]
        for chunk in GitHubQuery.chunks(of: branches) {
            let (query, aliasToBranch) = GitHubQuery.build(branches: chunk)
            let data = try runGH(query: query, in: repository)
            out.merge(try GitHubQuery.decode(data, aliasToBranch: aliasToBranch)) { _, new in new }
        }
        return out
    }

    /// `{owner}` and `{repo}` are gh's own placeholders — it resolves them
    /// from its working directory, so they are passed literally.
    private func runGH(query: String, in repository: String) throws -> Data {
        let command = ([
            "gh", "api", "graphql",
            "-f", "query=" + query,
            "-F", "owner={owner}",
            "-F", "name={repo}",
        ] as [String]).map(shellQuoted).joined(separator: " ")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // A GUI-launched app inherits no shell PATH, and `gh` lives outside
        // the system directories, so it is only reachable through a login
        // shell.
        //
        // `-m` (job control) is what makes the timeout work. Without it the
        // login shell's children join Plume's own process group, so killing
        // the shell leaves `gh` alive holding the pipe's write end — the read
        // then blocks until `gh` finishes on its own, and the deadline buys
        // nothing. With it the child leads its own group, and `kill(-pid)`
        // reaps the whole tree.
        process.arguments = ["-mc", LoginShellCommand.wrap("exec " + command)]
        process.currentDirectoryURL = URL(fileURLWithPath: repository)

        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error

        do {
            try process.run()
        } catch {
            throw ForgeError(message: "could not run gh: \(error.localizedDescription)")
        }

        let timedOut = Mutex(false)
        let deadline = DispatchWorkItem { [processIdentifier = process.processIdentifier] in
            timedOut.withLock { $0 = true }
            kill(-processIdentifier, SIGKILL)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout.seconds, execute: deadline)
        defer { deadline.cancel() }

        // Read both pipes before waiting: a full pipe deadlocks the child,
        // and a rollup for a busy repo is far bigger than a pipe buffer.
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = error.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        if timedOut.withLock({ $0 }) {
            throw ForgeError(message: "gh timed out", kind: .timedOut)
        }
        guard process.terminationStatus == 0 else {
            let stderr = String(decoding: errorData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw ForgeError(message: stderr.isEmpty
                ? "gh exited \(process.terminationStatus)"
                : stderr)
        }
        return outputData
    }
}

private extension Duration {
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
