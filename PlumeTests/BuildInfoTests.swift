#if DEBUG
import Foundation
import Testing

@testable import Plume

struct BuildInfoTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "GMT")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }()

    private let locale = Locale(identifier: "en_US_POSIX")

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    // MARK: branch(fromHEAD:)

    @Test func branchFromHEADReadsARef() {
        #expect(BuildInfo.branch(fromHEAD: "ref: refs/heads/ryanm/plume-175-debug-worktree-label\n")
            == "ryanm/plume-175-debug-worktree-label")
    }

    @Test func branchFromHEADShortensADetachedSHA() {
        let sha = String(repeating: "a1b2c3", count: 6) + "aaaa" // 40 hex chars
        #expect(BuildInfo.branch(fromHEAD: sha + "\n") == String(sha.prefix(7)))
    }

    @Test func branchFromHEADReturnsNilForGarbage() {
        #expect(BuildInfo.branch(fromHEAD: "not a HEAD file") == nil)
        #expect(BuildInfo.branch(fromHEAD: "") == nil)
    }

    // MARK: gitDirectory(forSourceRoot:)

    @Test func gitDirectoryUsesADirectoryDirectly() throws {
        let root = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let dotGit = root.appending(path: ".git")
        try FileManager.default.createDirectory(at: dotGit, withIntermediateDirectories: true)

        #expect(BuildInfo.gitDirectory(forSourceRoot: root) == dotGit)
    }

    @Test func gitDirectoryFollowsAnAbsoluteGitFile() throws {
        let root = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let realGitDir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: realGitDir) }
        try "gitdir: \(realGitDir.path)\n".write(to: root.appending(path: ".git"), atomically: true, encoding: .utf8)

        #expect(BuildInfo.gitDirectory(forSourceRoot: root)?.path == realGitDir.path)
    }

    @Test func gitDirectoryFollowsARelativeGitFile() throws {
        let root = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appending(path: "worktrees/foo")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try "gitdir: worktrees/foo\n".write(to: root.appending(path: ".git"), atomically: true, encoding: .utf8)

        #expect(BuildInfo.gitDirectory(forSourceRoot: root)?.path == nested.path)
    }

    private func makeScratchDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "BuildInfoTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: label

    @Test func labelForTodayShowsBranchAndTimeAlone() {
        let now = date(2026, 9, 24, 15, 30)
        let builtAt = date(2026, 9, 24, 9, 5)
        let label = BuildInfo.label(branch: "main", builtAt: builtAt, now: now, calendar: calendar, locale: locale)
        #expect(label?.contains("main") == true)
        #expect(label?.contains("9:05") == true)
        #expect(label?.contains("yesterday") == false)
        #expect(label?.contains("ago") == false)
    }

    @Test func labelForYesterdaySaysYesterdayAndTheTime() {
        let now = date(2026, 9, 24, 15, 30)
        let builtAt = date(2026, 9, 23, 9, 5)
        let label = BuildInfo.label(branch: "main", builtAt: builtAt, now: now, calendar: calendar, locale: locale)
        #expect(label?.contains("yesterday") == true)
        #expect(label?.contains("9:05") == true)
    }

    @Test func labelForSeveralDaysAgoOmitsTheTime() {
        let now = date(2026, 9, 24, 15, 30)
        let builtAt = date(2026, 9, 21, 9, 5)
        let label = BuildInfo.label(branch: "main", builtAt: builtAt, now: now, calendar: calendar, locale: locale)
        #expect(label?.contains("3 days ago") == true)
        #expect(label?.contains("9:05") == false)
    }

    @Test func labelWithNoBranchShowsTheTimeAlone() {
        let now = date(2026, 9, 24, 15, 30)
        let builtAt = date(2026, 9, 24, 9, 5)
        let label = BuildInfo.label(branch: nil, builtAt: builtAt, now: now, calendar: calendar, locale: locale)
        #expect(label?.contains("9:05") == true)
        #expect(label?.contains("·") == false)
    }

    @Test func labelWithNeitherPieceIsNil() {
        let now = date(2026, 9, 24, 15, 30)
        #expect(BuildInfo.label(branch: nil, builtAt: nil, now: now, calendar: calendar, locale: locale) == nil)
    }
}
#endif
