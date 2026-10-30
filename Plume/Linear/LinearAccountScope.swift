import Foundation

/// Which connected workspaces a project's tasks see. Nil means all of them.
nonisolated enum LinearAccountScope {
    static func filter(_ accounts: [LinearAccount], allowing orgIDs: [String]?) -> [LinearAccount] {
        guard let orgIDs else { return accounts }
        return accounts.filter { orgIDs.contains($0.orgID) }
    }

    /// The selection after switching one workspace, with nil again once every
    /// connected workspace is on, so a workspace connected later still shows.
    static func toggling(_ orgID: String, on: Bool, selection: [String]?, connected: [String]) -> [String]? {
        var allowed = connected.filter { selection?.contains($0) ?? true }
        if on {
            if !allowed.contains(orgID) { allowed.append(orgID) }
        } else {
            allowed.removeAll { $0 == orgID }
        }
        return connected.allSatisfy(allowed.contains) ? nil : allowed
    }

    /// `repository` is a task's `repoPath`; a nil one belongs to no project.
    static func allowedOrgIDs(repository: String?, configuration: ProjectsConfiguration) -> [String]? {
        guard let repository else { return allowedOrgIDs(root: nil, configuration: configuration) }
        return allowedOrgIDs(root: ProjectRoot.root(forRepositoryDirectory: repository), configuration: configuration)
    }

    static func allowedOrgIDs(root: String?, configuration: ProjectsConfiguration) -> [String]? {
        guard let root else { return configuration.defaults.linearOrgIDs }
        return configuration.settings(forRepository: root).linearOrgIDs
    }
}

/// Resolves a tab's directory to its project's scope. Asking git for the
/// project root takes a process, so the answer is remembered per directory.
@MainActor
final class LinearDirectoryScopes {
    private var roots: [String: String?] = [:]

    func allowedOrgIDs(forDirectory directory: String?) async -> [String]? {
        let configuration = AppSettings.shared.projectsConfiguration
        guard let directory else { return LinearAccountScope.allowedOrgIDs(root: nil, configuration: configuration) }
        let isScoped = configuration.defaults.linearOrgIDs != nil
            || configuration.repositories.values.contains { $0.linearOrgIDs != nil }
        guard isScoped else { return nil }
        let root: String?
        if let known = roots[directory] {
            root = known
        } else {
            root = await Task.detached { ProjectRoot.containing(directory) }.value
            roots[directory] = .some(root)
        }
        return LinearAccountScope.allowedOrgIDs(root: root, configuration: configuration)
    }
}
