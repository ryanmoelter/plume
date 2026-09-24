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

    /// The source root's branch at launch, not at build time — a checkout
    /// after the build shows the new branch.
    static var branch: String? {
        if let root = sourceRoot,
           let gitDirectory = gitDirectory(forSourceRoot: root),
           let head = try? String(contentsOf: gitDirectory.appending(path: "HEAD"), encoding: .utf8),
           let branch = branch(fromHEAD: head) {
            return branch
        }
        return sourceRoot?.lastPathComponent
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

    /// The build time reads as a bare time today, and gains a relative day
    /// marker once it no longer is.
    static func label(
        branch: String?,
        builtAt: Date?,
        now: Date,
        calendar: Calendar,
        locale: Locale
    ) -> String? {
        let parts = [branch, timeDescription(builtAt: builtAt, now: now, calendar: calendar, locale: locale)]
            .compactMap { $0 }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " · ")
    }

    private static func timeDescription(builtAt: Date?, now: Date, calendar: Calendar, locale: Locale) -> String? {
        guard let builtAt else { return nil }

        var timeStyle = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar)
        timeStyle.timeZone = calendar.timeZone
        let time = builtAt.formatted(timeStyle)

        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: builtAt),
            to: calendar.startOfDay(for: now)
        ).day ?? 0
        guard days > 0 else { return time }

        let formatter = RelativeDateTimeFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        formatter.dateTimeStyle = .named
        let relative = formatter.localizedString(from: DateComponents(day: -days))
        return days == 1 ? "\(relative), \(time)" : relative
    }
}
#endif
