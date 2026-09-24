#if DEBUG
import Darwin
import Foundation

enum BuildInfo {
    static var sourceRoot: URL? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "PlumeBuildSourceRoot") as? String,
              !raw.isEmpty
        else { return nil }
        return URL(fileURLWithPath: raw)
    }

    static var worktreeName: String? { sourceRoot?.lastPathComponent }

    /// The source root's branch at launch, not at build time — a checkout
    /// after the build shows the new branch.
    static var branch: String? {
        guard let root = sourceRoot,
              let gitDirectory = gitDirectory(forSourceRoot: root),
              let head = try? String(contentsOf: gitDirectory.appending(path: "HEAD"), encoding: .utf8)
        else { return nil }
        return branch(fromHEAD: head)
    }

    /// The modification date of the image holding this code — in Debug,
    /// `Plume.debug.dylib`, which relinks on every build that changes code.
    static var builtAt: Date? {
        var info = Dl_info()
        guard dladdr(#dsohandle, &info) != 0, let fname = info.dli_fname else { return nil }
        let path = String(cString: fname)
        return try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date
    }

    /// Resolves `<root>/.git` to the real git directory. A worktree's `.git`
    /// is a file pointing at the shared repository's `worktrees/<name>`
    /// directory rather than a directory of its own.
    static func gitDirectory(forSourceRoot root: URL) -> URL? {
        let dotGit = root.appending(path: ".git")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) else { return nil }
        if isDirectory.boolValue {
            return dotGit
        }
        guard let contents = try? String(contentsOf: dotGit, encoding: .utf8),
              let line = contents.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") })
        else { return nil }
        let path = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path)
        }
        return root.appending(path: path).standardized
    }

    /// `ref: refs/heads/<name>` names a branch; a bare 40-hex SHA is a
    /// detached HEAD, shown as its short form.
    static func branch(fromHEAD contents: String) -> String? {
        let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        let refPrefix = "ref: refs/heads/"
        if trimmed.hasPrefix(refPrefix) {
            let name = String(trimmed.dropFirst(refPrefix.count))
        // A reftable repository's HEAD is a stub naming this placeholder.
        return name == ".invalid" ? nil : name
        }
        if trimmed.count == 40, trimmed.allSatisfy({ $0.isHexDigit }) {
            return String(trimmed.prefix(7))
        }
        return nil
    }

    /// `15:33 today`, `15:33 yesterday`, then just `3 days ago`.
    static func buildTime(_ builtAt: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
        var timeStyle = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar)
        timeStyle.timeZone = calendar.timeZone
        let time = builtAt.formatted(timeStyle)

        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: builtAt),
            to: calendar.startOfDay(for: now)
        ).day ?? 0

        let formatter = RelativeDateTimeFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        formatter.dateTimeStyle = .named
        let relative = formatter.localizedString(from: DateComponents(day: -max(days, 0)))
        return days <= 1 ? "\(time) \(relative)" : relative
    }
}
#endif
