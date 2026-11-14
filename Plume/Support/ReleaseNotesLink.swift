import Foundation

nonisolated enum ReleaseNotesLink {
    static let releasesList = URL(string: "https://github.com/ryanmoelter/plume/releases")!

    /// The release page for `marketingVersion`, tag suffix included. A Debug
    /// build, or a blank version, has no release to point at.
    static func url(marketingVersion: String?, isDebugBuild: Bool) -> URL {
        let version = marketingVersion?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !isDebugBuild, !version.isEmpty,
              let tag = "v\(version)".addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
        else { return releasesList }
        return URL(string: "https://github.com/ryanmoelter/plume/releases/tag/\(tag)") ?? releasesList
    }

    static var current: URL {
        #if DEBUG
        let isDebug = true
        #else
        let isDebug = false
        #endif
        return url(
            marketingVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            isDebugBuild: isDebug
        )
    }
}
