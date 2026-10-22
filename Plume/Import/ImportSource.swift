import Foundation

/// An app Plume can import workspaces from. The sheet, menu and settings read
/// everything source-specific from here.
nonisolated enum ImportSource: String, Identifiable, CaseIterable, Sendable {
    case cmux
    case orca

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .cmux: "cmux"
        case .orca: "Orca"
        }
    }

    var groupMirrorLabel: String {
        switch self {
        case .cmux: "Mirror cmux groups"
        case .orca: "Mirror Orca repos"
        }
    }

    /// Shown above the rows while the source app is running.
    var runningWarning: String? {
        switch self {
        case .cmux: nil
        case .orca:
            "Orca is still running. Agents in its terminals keep running after Orca quits, so importing them puts a second copy on the same conversation. In Orca, choose Kill all sessions (Settings ▸ Terminal ▸ Manage Sessions), then quit Orca."
        }
    }

    /// Shown after an import made while the source app was running.
    var postImportReminder: String? {
        switch self {
        case .cmux: nil
        case .orca:
            "Orca's copies of these agents are still running. In Orca, choose Kill all sessions (Settings ▸ Terminal ▸ Manage Sessions), then quit Orca."
        }
    }

    /// Unvalidated rows, read off the main actor.
    func loadCandidates() async -> ImportSourceLoad {
        switch self {
        case .cmux:
            await Task.detached {
                ImportSourceLoad(
                    candidates: CmuxCandidateBuilder.candidates(from: CmuxSnapshot.loadingFromDisk()),
                    emptyStateText: CmuxLocations.isInstalled()
                        ? "cmux has no saved workspaces."
                        : "No cmux session file at \(CmuxLocations.sessionFile.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))"
                )
            }.value
        case .orca:
            await Task.detached {
                let snapshot = OrcaSnapshot.loadingFromDisk()
                let emptyStateText = if !OrcaLocations.isInstalled() {
                    "Orca is not installed."
                } else if snapshot.isUnsupportedSchema {
                    "This version of Orca isn't supported yet."
                } else if snapshot.isUnreadable {
                    "Plume couldn't read Orca's saved state."
                } else {
                    "Orca has no saved worktrees."
                }
                return ImportSourceLoad(
                    candidates: OrcaCandidateBuilder.candidates(from: snapshot),
                    emptyStateText: emptyStateText,
                    sourceIsRunning: OrcaRunningState.isRunning()
                )
            }.value
        }
    }

    /// One per import sheet, so state a source builds lazily is shared by every row.
    func makeValidator() -> ImportSourceValidator {
        switch self {
        case .cmux:
            ImportSourceValidator { await CmuxImportValidator.validating($0) }
        case .orca:
            ImportSourceValidator { [orca = OrcaImportValidator()] in await orca.validating($0) }
        }
    }
}

nonisolated struct ImportSourceValidator: Sendable {
    private let validate: @Sendable (ImportCandidate) async -> ImportCandidate

    init(_ validate: @escaping @Sendable (ImportCandidate) async -> ImportCandidate) {
        self.validate = validate
    }

    /// Reads files and runs git, so it must not run on the main actor.
    @concurrent
    func validating(_ candidate: ImportCandidate) async -> ImportCandidate {
        await validate(candidate)
    }
}

nonisolated struct ImportSourceLoad: Sendable {
    let candidates: [ImportCandidate]
    /// Shown when `candidates` is empty.
    let emptyStateText: String
    /// The source app, or anything it left running, could still be driving
    /// the agents an import would resume.
    var sourceIsRunning = false
}
