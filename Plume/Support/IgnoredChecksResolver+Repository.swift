import Foundation

nonisolated extension IgnoredChecksResolver {
    /// The full ignore list for the repository containing `repository`.
    /// Blocks on `git` to find the project, so call this off the main actor.
    static func resolve(repository: String, plumeSetting: [String], configuration: ProjectsConfiguration) -> Set<String> {
        let settings = ProjectRoot.containing(repository).map(configuration.settings(forRepository:)) ?? configuration.defaults
        return resolve(settings: settings, plumeSetting: plumeSetting)
    }
}
