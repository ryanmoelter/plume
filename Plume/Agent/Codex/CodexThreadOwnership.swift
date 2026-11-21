import Foundation

@MainActor
enum CodexThreadOwnership {
    static func isActiveWriterConflict(_ error: Error, threadID: String?) -> Bool {
        guard let threadID, !threadID.isEmpty,
              let failure = error as? CodexAppServerClient.Failure,
              case .server(let code, let message) = failure,
              code == -32600 else { return false }
        return message == "thread \(threadID) already has an active writer"
    }
}
