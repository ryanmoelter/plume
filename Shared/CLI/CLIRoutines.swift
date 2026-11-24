import Foundation

/// A routine as `plume routine` prints it.
nonisolated struct CLIRoutineInfo: Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var isEnabled: Bool
    /// "Weekdays at 9:00", as the Routines page shows it.
    var schedule: String
    var nextRunAt: Date?
    var lastRunAt: Date?
    /// Why the latest run in this app session failed to start.
    var lastError: String?
    /// The task the latest run in this app session started.
    var lastTaskID: UUID?
}

nonisolated enum CLIRoutineCommand: Equatable, Sendable {
    case list(json: Bool)
    /// By ID, exact name, or a unique part of a name.
    case run(String)
}
