import Foundation
import SwiftData

/// Starts one run of a routine: a new task in the Routines group, its agent
/// launched with the routine's prompt the way Home starts a task.
@MainActor
enum RoutineRunner {
    nonisolated enum Failure: Error, Equatable, LocalizedError {
        case emptyPrompt
        case folderMissing(String)
        case untrusted(String)
        case cliMissing(AgentProviderKind)

        var errorDescription: String? {
            switch self {
            case .emptyPrompt: "The routine has no prompt."
            case .folderMissing(let path): "The folder \(path) doesn't exist."
            case .untrusted(let path):
                "Claude Code hasn't been trusted in \(path). Open it in a terminal tab and accept the trust prompt."
            case .cliMissing(let provider): "\(provider.displayName) isn't installed."
            }
        }
    }

    /// What a run needs before any task exists. Nil means it can start.
    nonisolated static func preflight(
        prompt: String,
        folder: String,
        provider: AgentProviderKind,
        checksTrust: Bool,
        folderExists: (String) -> Bool,
        isTrusted: (String) -> Bool,
        isInstalled: (AgentProviderKind) -> Bool
    ) -> Failure? {
        if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .emptyPrompt }
        if !folderExists(folder) { return .folderMissing(folder) }
        if !isInstalled(provider) { return .cliMissing(provider) }
        if provider == .claudeCode, checksTrust, !isTrusted(folder) { return .untrusted(folder) }
        return nil
    }

    static func start(_ routine: Routine, in context: ModelContext) async throws -> WorkTask {
        let snapshot = RoutinePlanInputs(routine)
        let failure = await Task.detached(priority: .userInitiated) { () -> Failure? in
            let installed = snapshot.provider == .claudeCode ? nil : await AgentCLIAvailability.shared.load()
            return preflight(
                prompt: snapshot.prompt,
                folder: snapshot.folderPath,
                provider: snapshot.provider,
                // A new worktree's folder doesn't exist yet; the launch
                // itself refuses it if untrusted, which `start` reads back.
                checksTrust: !snapshot.usesNewWorktree,
                folderExists: { FileManager.default.fileExists(atPath: $0) },
                isTrusted: { ClaudeTrustStore.isTrusted($0) },
                isInstalled: { provider in
                    provider == .claudeCode ? ClaudeCLILocator.isAvailable() : installed?.contains(provider) != false
                }
            )
        }.value
        if let failure { throw failure }

        var prefix = WorkspaceProvisioner.defaultBranchPrefix
        if snapshot.usesNewWorktree {
            prefix = await GitService.shared.configuredBranchPrefix(
                in: snapshot.repoPath, configuration: AppSettings.shared.projectsConfiguration
            ) ?? prefix
        }
        let group = RoutineGroup.findOrCreate(in: context)
        let plan = snapshot.plan(groupID: group.id, branchPrefix: prefix)
        let task = try await HomeTaskStarter.start(plan, in: context)
        task.title = snapshot.name
        if let tab = task.orderedTabs.first, let path = UntrustedDirectoryStore.shared.path(forTab: tab.id) {
            throw Failure.untrusted(path)
        }
        return task
    }
}

/// A routine's fields as one run reads them, so the run doesn't touch the
/// model across an `await`.
nonisolated struct RoutinePlanInputs: Equatable, Sendable {
    var name: String
    var prompt: String
    var folderPath: String
    var repoPath: String?
    var runsInNewWorktree: Bool
    var choices: TabLaunchChoices

    var provider: AgentProviderKind {
        choices.providerID.flatMap(AgentProviderKind.init(rawValue:)) ?? .claudeCode
    }

    var usesNewWorktree: Bool { runsInNewWorktree && repoPath != nil }

    @MainActor
    init(_ routine: Routine) {
        self.init(
            name: routine.name,
            prompt: routine.prompt,
            folderPath: routine.folderPath,
            repoPath: routine.repoPath,
            runsInNewWorktree: routine.runsInNewWorktree,
            choices: routine.launchChoices
        )
    }

    init(
        name: String, prompt: String, folderPath: String, repoPath: String?,
        runsInNewWorktree: Bool, choices: TabLaunchChoices
    ) {
        self.name = name
        self.prompt = prompt
        self.folderPath = folderPath
        self.repoPath = repoPath
        self.runsInNewWorktree = runsInNewWorktree
        self.choices = choices
    }

    func plan(groupID: UUID?, branchPrefix: String, branchSuffix: String = WorkspaceProvisioner.randomSuffix()) -> HomeTaskPlan {
        var choices = choices
        choices.transportRaw = AgentTransport.headless.rawValue
        guard usesNewWorktree, let repoPath else {
            return HomeTaskPlan(
                groupID: groupID, workspace: .directory(path: folderPath, repoPath: repoPath),
                message: prompt, choices: choices
            )
        }
        let branch = WorkspaceProvisioner.suggestedBranchName(
            for: name.isEmpty ? HomeDestinationCatalog.branchSeed(from: prompt) : name,
            suffix: branchSuffix, prefix: branchPrefix
        )
        return HomeTaskPlan(
            groupID: groupID,
            workspace: .newWorktree(repository: repoPath, branch: branch),
            subfolder: subfolder(inRepository: repoPath),
            message: prompt,
            choices: choices
        )
    }

    /// `folderPath` relative to its project's root, so each new worktree
    /// runs in the same subfolder. Nil at the root.
    private func subfolder(inRepository repository: String) -> String? {
        let root = ProjectRoot.root(forRepositoryDirectory: repository)
        guard folderPath.hasPrefix(root + "/") else { return nil }
        let relative = String(folderPath.dropFirst(root.count + 1))
        return relative.isEmpty ? nil : relative
    }
}
