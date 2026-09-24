/// The user-facing app name. Bundle names use the same per-configuration
/// value; executable names, CLI commands and persisted paths stay stable.
nonisolated enum AppIdentity {
    static let displayName: String = {
        #if DEBUG
        "Plume α"
        #else
        "Plume"
        #endif
    }()
}
