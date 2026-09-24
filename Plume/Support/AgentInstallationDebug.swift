#if DEBUG
import Foundation
import Observation

/// Session-only UI fixtures; never change actual executable discovery.
@Observable
final class AgentInstallationDebug {
    static let shared = AgentInstallationDebug()

    enum Installation: String, CaseIterable, Identifiable {
        case automatic, installed, missing
        var id: Self { self }
        var label: String {
            switch self {
            case .automatic: "Detect automatically"
            case .installed: "Installed"
            case .missing: "Not installed"
            }
        }
    }

    var overrides: [AgentProviderKind: Installation] = [:]

    func applying(to detected: Set<AgentProviderKind>) -> Set<AgentProviderKind> {
        var result = detected
        for (provider, state) in overrides {
            switch state {
            case .automatic: break
            case .installed: result.insert(provider)
            case .missing: result.remove(provider)
            }
        }
        return result
    }
}
#endif
