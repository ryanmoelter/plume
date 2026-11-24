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

    /// Runs `preflight` against the disk and the installed CLIs, off the
    /// main actor.
    static func check(_ inputs: RoutinePlanInputs) async -> Failure? {
        await Task.detached(priority: .userInitiated) { () -> Failure? in
            let installed = inputs.provider == .claudeCode ? nil : await AgentCLIAvailability.shared.load()
            return preflight(
                prompt: inputs.prompt,
                folder: inputs.folderPath,
                provider: inputs.provider,
                // A new worktree's folder doesn't exist yet; the launch
                // itself refuses it if untrusted, which `start` reads back.
                checksTrust: !inputs.usesNewWorktree,
                folderExists: { FileManager.default.fileExists(atPath: $0) },
                isTrusted: { ClaudeTrustStore.isTrusted($0) },
                isInstalled: { provider in
                    provider == .claudeCode ? ClaudeCLILocator.isAvailable() : installed?.contains(provider) != false
                }
            )
        }.value
    }

    /// Creates the run's task and launches its agent. `beforeLaunch` sees the
    /// task once its tab exists, before the agent can report any status.
    static func start(
        _ inputs: RoutinePlanInputs,
        in context: ModelContext,
        beforeLaunch: @MainActor (WorkTask) -> Void = { _ in }
    ) async throws -> WorkTask {
        var prefix = WorkspaceProvisioner.defaultBranchPrefix
        var checkoutRoot: String?
        if inputs.usesNewWorktree {
            prefix = await GitService.shared.configuredBranchPrefix(
                in: inputs.repoPath, configuration: AppSettings.shared.projectsConfiguration
            ) ?? prefix
            let folder = inputs.folderPath
            checkoutRoot = await Task.detached { GitRunner.checkoutFacts(containing: folder)?.checkoutRoot }.value
        }
        let group = RoutineGroup.findOrCreate(in: context)
        let plan = inputs.plan(groupID: group.id, branchPrefix: prefix, checkoutRoot: checkoutRoot)
        let task = try await HomeTaskStarter.start(plan, in: context, beforeLaunch: { task in
            task.title = inputs.name
            beforeLaunch(task)
        })
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

    /// `checkoutRoot` is the checkout holding `folderPath`, which may be a
    /// linked worktree rather than the repository itself.
    func plan(
        groupID: UUID?,
        branchPrefix: String,
        checkoutRoot: String? = nil,
        branchSuffix: String = WorkspaceProvisioner.randomSuffix()
    ) -> HomeTaskPlan {
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
            subfolder: subfolder(inCheckout: checkoutRoot ?? ProjectRoot.root(forRepositoryDirectory: repoPath)),
            message: prompt,
            choices: choices
        )
    }

    /// `folderPath` relative to its checkout, so each new worktree runs in
    /// the same subfolder. Nil at the root.
    private func subfolder(inCheckout checkout: String) -> String? {
        guard let relative = ProjectSubfolder.relativePath(of: folderPath, in: checkout), !relative.isEmpty else { return nil }
        return relative
    }
}
