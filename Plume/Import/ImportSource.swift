import Foundation

/// An app Plume can import workspaces from. The sheet, menu and settings read
/// everything source-specific from here.
nonisolated enum ImportSource: String, Identifiable, CaseIterable, Sendable {
    case cmux
    case orca
    case claudeDesktop

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .cmux: "cmux"
        case .orca: "Orca"
        case .claudeDesktop: "Claude desktop app"
        }
    }

    var groupMirrorLabel: String {
        switch self {
        case .cmux: "Mirror cmux groups"
        case .orca: "Mirror Orca repos"
        case .claudeDesktop: "Mirror Claude desktop repos"
        }
    }

    /// Shown above the rows while the source app is running.
    var runningWarning: String? {
        switch self {
        case .cmux: nil
        case .orca:
            "Orca is still running. Agents in its terminals keep running after Orca quits, so importing them puts a second copy on the same conversation. In Orca, choose Kill all sessions (Settings ▸ Terminal ▸ Manage Sessions), then quit Orca."
        case .claudeDesktop:
            "The Claude desktop app is still running. It may be driving these sessions, and resuming one here puts a second copy on the same conversation. Quit the app before importing."
        }
    }

    /// Shown after an import made while the source app was running.
    var postImportReminder: String? {
        switch self {
        case .cmux: nil
        case .orca:
            "Orca's copies of these agents are still running. In Orca, choose Kill all sessions (Settings ▸ Terminal ▸ Manage Sessions), then quit Orca."
        case .claudeDesktop:
            "Archive the imported sessions in the Claude desktop app, so the two apps do not both continue the same conversations."
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
        case .claudeDesktop:
            await Task.detached {
                let snapshot = ClaudeDesktopSnapshot.loadingFromDisk()
                let emptyStateText = if !ClaudeDesktopLocations.isInstalled() {
                    "The Claude desktop app is not installed."
                } else if snapshot.isLayoutUnrecognized {
                    "This version of the Claude desktop app isn't supported yet."
                } else if snapshot.unreadableCount > 0 {
                    "Plume couldn't read the Claude desktop app's saved sessions."
                } else {
                    "The Claude desktop app has no unarchived Code sessions."
                }
                return ImportSourceLoad(
                    candidates: ClaudeDesktopCandidateBuilder.candidates(from: snapshot),
                    emptyStateText: emptyStateText,
                    sourceIsRunning: ClaudeDesktopLocations.isRunning()
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
        case .claudeDesktop:
            ImportSourceValidator {
                await ImportValidator.validating(
                    $0,
                    configuration: .init(missingTranscript: .downgradeToTerminal, readsBranchFromGit: true)
                )
            }
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
