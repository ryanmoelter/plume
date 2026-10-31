import Foundation

/// A working directory split into the checkout it sits in and the folder
/// beneath that checkout, so the project reads as one choice and the
/// subfolder as another.
nonisolated struct ProjectSubfolder: Equatable, Sendable {
    let projectRoot: String
    let checkoutRoot: String
    /// Relative to `checkoutRoot`. Nil when the path is the checkout itself.
    let subfolder: String?

    /// Nil when `path` is not inside the checkout `facts` describes, which
    /// includes any folder git does not track.
    static func split(path: String, facts: CheckoutFacts?) -> ProjectSubfolder? {
        guard let facts else { return nil }
        let checkout = standardized(facts.checkoutRoot)
        let target = standardized(path)
        if target == checkout {
            return ProjectSubfolder(projectRoot: facts.projectRoot, checkoutRoot: facts.checkoutRoot, subfolder: nil)
        }
        let prefix = checkout.hasSuffix("/") ? checkout : checkout + "/"
        guard target.hasPrefix(prefix) else { return nil }
        return ProjectSubfolder(
            projectRoot: facts.projectRoot,
            checkoutRoot: facts.checkoutRoot,
            subfolder: String(target.dropFirst(prefix.count))
        )
    }

    /// The directory a task runs in for `subfolder` beneath `checkoutRoot`.
    static func directory(checkoutRoot: String, subfolder: String?) -> String {
        guard let subfolder, !subfolder.isEmpty else { return checkoutRoot }
        return (checkoutRoot as NSString).appendingPathComponent(subfolder)
    }

    private static func standardized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}
