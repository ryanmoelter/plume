import Foundation

/// The forge `submit` and `sync` talk to, through `gh` or `glab`. Both stay
/// soft dependencies: only the commands that need the forge require one.
nonisolated protocol StackForge: AnyObject {
    var kind: ForgeKind { get }
    /// `#` on GitHub, `!` on GitLab.
    var numberPrefix: String { get }
    /// `PR` on GitHub, `MR` on GitLab.
    var noun: String { get }
    /// `gh` or `glab`.
    var cliName: String { get }
    var isInstalled: Bool { get }
    /// Fails unless the CLI is installed and signed in.
    func requireReady() throws
    /// Pull requests by branch, or nil when the request failed.
    func pullRequests(forBranches branches: [String]) -> PullRequestMap?
    func editBase(number: Int, base: String) throws -> CLIProcessResult
    func create(head: String, base: String, title: String, body: String, draft: Bool) throws -> CLIProcessResult
    /// GitHub's native stacked PRs; nil on GitLab.
    var nativeStacks: (any GitHubNativeStacks)? { get }
}

nonisolated extension StackForge {
    /// Pull requests by branch, empty when the request failed.
    func pullRequestsOrEmpty(forBranches branches: [String]) -> PullRequestMap {
        pullRequests(forBranches: branches) ?? [:]
    }
}

/// A GitHub native stack: its number and its pull requests, bottom first.
nonisolated struct GitHubNativeStack: Equatable, Sendable {
    var number: Int?
    var pullRequestNumbers: [Int]
}

/// GitHub's stack API. Cosmetic to `stack`: branches and PR bases are right
/// without it, so every failure degrades to a missing stack navigator.
nonisolated protocol GitHubNativeStacks: AnyObject {
    /// Whether the repository has the feature, probed once and cached.
    func isEnabled() -> Bool
    /// Caches the feature as off after a call unexpectedly fails.
    func markUnavailable()
    /// The stack holding `pullRequest`, merged members included.
    func stack(containing pullRequest: Int) -> GitHubNativeStack?
    /// Registers a stack; the number is read from the response when it has one.
    func create(_ pullRequests: [Int]) -> (ok: Bool, number: Int?)
    func add(_ pullRequests: [Int], to stack: Int) -> Bool
}

/// `gh`, in `workingDirectory`, which resolves its `{owner}`/`{repo}`.
nonisolated final class GitHubStackForge: StackForge {
    let workingDirectory: String?
    /// Holds the cached feature probe.
    let stateDirectory: String

    init(workingDirectory: String?, stateDirectory: String) {
        self.workingDirectory = workingDirectory
        self.stateDirectory = stateDirectory
    }

    var kind: ForgeKind { .github }
    var numberPrefix: String { "#" }
    var noun: String { "PR" }
    var cliName: String { "gh" }
    var isInstalled: Bool { CLIProcess.which("gh") != nil }

    func requireReady() throws {
        try requireCLI(cliName)
    }

    func pullRequests(forBranches branches: [String]) -> PullRequestMap? {
        GitHubBackend(workingDirectory: workingDirectory, includeStacks: true).pullRequests(forBranches: branches)
    }

    func editBase(number: Int, base: String) throws -> CLIProcessResult {
        try CLIProcess.run(["gh", "pr", "edit", String(number), "--base", base], check: false, workingDirectory: workingDirectory)
    }

    func create(head: String, base: String, title: String, body: String, draft: Bool) throws -> CLIProcessResult {
        var arguments = ["gh", "pr", "create", "--head", head, "--base", base, "--title", title, "--body", body]
        if draft { arguments.append("--draft") }
        return try CLIProcess.run(arguments, check: false, workingDirectory: workingDirectory)
    }

    var nativeStacks: (any GitHubNativeStacks)? {
        GitHubStackAPI(workingDirectory: workingDirectory, cacheFile: "\(stateDirectory)/github-stacks-enabled")
    }
}

/// Fails unless `name` is on PATH and signed in.
private nonisolated func requireCLI(_ name: String) throws {
    guard CLIProcess.which(name) != nil else {
        throw CLIFailure("\(name) is required for this command (brew install \(name))")
    }
    let status = (try? CLIProcess.run([name, "auth", "status"], check: false))?.status ?? 1
    if status != 0 {
        throw CLIFailure("\(name) is not authenticated — run `\(name) auth login`")
    }
}

/// `gh api repos/{owner}/{repo}/stacks…`. Any 2xx is success; a response
/// body is read only opportunistically, since its shape is unverified.
nonisolated final class GitHubStackAPI: GitHubNativeStacks {
    let workingDirectory: String?
    /// Holds `true` or `false`: whether the repository has the feature. It
    /// rarely changes, so one probe serves every later run.
    let cacheFile: String

    init(workingDirectory: String?, cacheFile: String) {
        self.workingDirectory = workingDirectory
        self.cacheFile = cacheFile
    }

    func isEnabled() -> Bool {
        if let cached = try? String(contentsOfFile: cacheFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           cached == "true" || cached == "false" {
            return cached == "true"
        }
        // The collection endpoint 404s when the feature is off.
        let enabled = request("stacks").ok
        writeCache(enabled)
        return enabled
    }

    func markUnavailable() {
        writeCache(false)
    }

    func stack(containing pullRequest: Int) -> GitHubNativeStack? {
        let response = request("stacks?pull_request=\(pullRequest)")
        guard response.ok, let list = response.json as? [Any], let first = list.first as? [String: Any] else { return nil }
        let members = (first["pull_requests"] as? [Any] ?? []).compactMap { member -> Int? in
            if let number = member as? Int { return number }
            return (member as? [String: Any])?["number"] as? Int
        }
        return GitHubNativeStack(number: first["number"] as? Int, pullRequestNumbers: members)
    }

    func create(_ pullRequests: [Int]) -> (ok: Bool, number: Int?) {
        let response = request("stacks", method: "POST", body: ["pull_requests": pullRequests])
        return (response.ok, (response.json as? [String: Any])?["number"] as? Int)
    }

    func add(_ pullRequests: [Int], to stack: Int) -> Bool {
        request("stacks/\(stack)/add", method: "POST", body: ["pull_requests": pullRequests]).ok
    }

    private func request(_ path: String, method: String? = nil, body: [String: Any]? = nil) -> (ok: Bool, json: Any?) {
        var arguments = ["gh", "api", "repos/{owner}/{repo}/\(path)"]
        if let method { arguments += ["-X", method] }
        var input: String?
        if let body, let data = try? JSONSerialization.data(withJSONObject: body) {
            arguments += ["--input", "-"]
            input = String(decoding: data, as: UTF8.self)
        }
        guard let result = try? CLIProcess.run(arguments, check: false, input: input, workingDirectory: workingDirectory),
              result.status == 0
        else { return (false, nil) }
        return (true, try? JSONSerialization.jsonObject(with: Data(result.stdout.utf8)))
    }

    private func writeCache(_ enabled: Bool) {
        let directory = (cacheFile as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try? (enabled ? "true\n" : "false\n").write(toFile: cacheFile, atomically: true, encoding: .utf8)
    }
}

/// `glab`, for the project at `fullPath`.
nonisolated final class GitLabStackForge: StackForge {
    let fullPath: String
    let workingDirectory: String?

    init(fullPath: String, workingDirectory: String?) {
        self.fullPath = fullPath
        self.workingDirectory = workingDirectory
    }

    var kind: ForgeKind { .gitlab }
    var numberPrefix: String { "!" }
    var noun: String { "MR" }
    var cliName: String { "glab" }
    var isInstalled: Bool { CLIProcess.which("glab") != nil }

    func requireReady() throws {
        try requireCLI(cliName)
    }

    func pullRequests(forBranches branches: [String]) -> PullRequestMap? {
        GitLabBackend(fullPath: fullPath, workingDirectory: workingDirectory).pullRequests(forBranches: branches)
    }

    func editBase(number: Int, base: String) throws -> CLIProcessResult {
        try CLIProcess.run(["glab", "mr", "update", String(number), "--target-branch", base], check: false, workingDirectory: workingDirectory)
    }

    func create(head: String, base: String, title: String, body: String, draft: Bool) throws -> CLIProcessResult {
        var arguments = [
            "glab", "mr", "create", "--source-branch", head, "--target-branch", base,
            "--title", title, "--description", body, "--yes",
        ]
        if draft { arguments.append("--draft") }
        return try CLIProcess.run(arguments, check: false, workingDirectory: workingDirectory)
    }

    /// GitLab has no native stack object.
    var nativeStacks: (any GitHubNativeStacks)? { nil }
}
