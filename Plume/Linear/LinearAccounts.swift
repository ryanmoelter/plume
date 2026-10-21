import Foundation
import Observation

/// How one connected workspace is doing, as Settings shows it.
nonisolated enum LinearAccountStatus: Sendable, Equatable {
    case unknown
    case connected
    case unauthorized
    case rateLimited(until: Date)
    case failed(String)
}

/// The connected Linear workspaces. Metadata lives in UserDefaults, and each
/// API key in the secret store under its `orgID`.
@MainActor
@Observable
final class LinearAccounts {
    typealias ClientFactory = @Sendable (
        _ apiKey: @escaping @Sendable () -> String?,
        _ onRateLimit: @escaping @Sendable (LinearRateLimit) -> Void
    ) -> LinearClient

    enum Change: Equatable {
        /// A new account, or a new key for an existing one.
        case keyChanged(orgID: String)
        case removed(orgID: String)
    }

    /// UserDefaults are shared between Debug and Release, so Debug lists its
    /// own accounts to match its own Keychain service.
#if DEBUG
    static let defaultsKey = "linearAccounts.debug"
#else
    static let defaultsKey = "linearAccounts"
#endif

    nonisolated static let graphQLClient: ClientFactory = { apiKey, onRateLimit in
        LinearGraphQLClient(apiKey: apiKey, onRateLimit: onRateLimit)
    }

    private(set) var accounts: [LinearAccount] = []

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored let secrets: SecretStore
    @ObservationIgnored let clientFactory: ClientFactory
    @ObservationIgnored var onChange: ((Change) -> Void)?

    init(
        defaults: UserDefaults = .standard,
        secrets: SecretStore = KeychainSecretStore(),
        clientFactory: @escaping ClientFactory = LinearAccounts.graphQLClient
    ) {
        self.defaults = defaults
        self.secrets = secrets
        self.clientFactory = clientFactory
        if let data = defaults.data(forKey: Self.defaultsKey),
           let stored = try? JSONDecoder().decode([LinearAccount].self, from: data) {
            accounts = stored
        }
    }

    /// Verifies the key against Linear before storing anything, so a typo
    /// never lands in the Keychain.
    @discardableResult
    func add(apiKey: String) async throws -> LinearAccount {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw LinearError.unauthorized }
        let client = clientFactory({ key }, { _ in })
        let account = try await client.fetchViewer()
        try secrets.write(key, account: account.orgID)
        if let index = accounts.firstIndex(where: { $0.orgID == account.orgID }) {
            if accounts[index] != account { accounts[index] = account }
        } else {
            accounts.append(account)
        }
        persist()
        onChange?(.keyChanged(orgID: account.orgID))
        return account
    }

    func remove(orgID: String) {
        guard accounts.contains(where: { $0.orgID == orgID }) else { return }
        accounts.removeAll { $0.orgID == orgID }
        try? secrets.delete(account: orgID)
        persist()
        onChange?(.removed(orgID: orgID))
    }

    func apiKey(for orgID: String) -> String? {
        secrets.read(account: orgID)
    }

    /// A client that reads the account's key per request, so a key change
    /// needs no new client.
    func makeClient(orgID: String, onRateLimit: @escaping @Sendable (LinearRateLimit) -> Void) -> LinearClient {
        let secrets = secrets
        return clientFactory({ secrets.read(account: orgID) }, onRateLimit)
    }

    /// The workspaces whose catalog has `teamKey`, in catalog order. More than
    /// one means two workspaces share a key.
    static func owners(ofTeamKey teamKey: String, catalogs: [LinearCatalog]) -> [String] {
        let key = teamKey.uppercased()
        return catalogs.filter { $0.teamKeys.contains(key) }.map(\.orgID)
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(accounts) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
