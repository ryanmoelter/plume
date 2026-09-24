import Observation

/// One installation snapshot for menus, Settings, and the sidebar. Readers
/// keep using it while activation refreshes the real login-shell lookup.
@Observable
final class AgentCLIAvailability {
    static let shared = AgentCLIAvailability()

    private(set) var providers: Set<AgentProviderKind>?
    @ObservationIgnored private var pending: Task<Set<AgentProviderKind>, Never>?
    @ObservationIgnored private let probe: @Sendable () async -> Set<AgentProviderKind>

    init(probe: @escaping @Sendable () async -> Set<AgentProviderKind> = {
        await Task.detached(priority: .userInitiated) {
            AgentCLIInstallation.installedProviders()
        }.value
    }) {
        self.probe = probe
    }

    /// Only the first reader waits for discovery; subsequent reads never
    /// wait for an in-flight refresh.
    @discardableResult
    func load() async -> Set<AgentProviderKind> {
        if let providers { return providers }
        return await refresh()
    }

    @discardableResult
    func refresh() async -> Set<AgentProviderKind> {
        if let pending { return await pending.value }
        let task = Task { await probe() }
        pending = task
        let result = await task.value
        providers = result
        pending = nil
        return result
    }
}
