import Testing
import Foundation
@testable import Plume

/// Covers the one-time removal of the statusline capture earlier versions
/// installed into `~/.claude/settings.json`. Every case runs against a scratch
/// directory — the real settings file is never touched.
@MainActor
struct StatuslineUninstallTests {
    private func makeScratchDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "StatuslineUninstallTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ json: String, to url: URL) throws {
        try json.write(to: url, atomically: true, encoding: .utf8)
    }

    /// The shape `install()` left behind: Plume's script in `settings.json`
    /// and the user's previous value in the backup.
    private func installedSettings(
        in scratch: URL,
        previous: String?
    ) throws -> (settingsURL: URL, backupURL: URL) {
        let settingsURL = scratch.appending(path: "settings.json")
        let backupURL = scratch.appending(path: "settings.json.plume-backup")

        try write(#"""
        { "statusLine": { "type": "command", "command": "\#(StatuslineUninstall.installedCommand)", "padding": 0 }, "model": "opus" }
        """#, to: settingsURL)

        let backup = previous.map {
            #"{ "statusLine": { "type": "command", "command": "\#($0)", "padding": 0 } }"#
        } ?? #"{ "statusLine": null }"#
        try write(backup, to: backupURL)

        return (settingsURL, backupURL)
    }

    private func settingsDictionary(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func restoresThePreviousStatusLine() throws {
        let scratch = makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let urls = try installedSettings(in: scratch, previous: "~/.scripts/.claude/statusline.sh")

        StatuslineUninstall.run(settingsURL: urls.settingsURL, backupURL: urls.backupURL)

        let dict = try settingsDictionary(at: urls.settingsURL)
        let statusLine = try #require(dict["statusLine"] as? [String: Any])
        #expect(statusLine["command"] as? String == "~/.scripts/.claude/statusline.sh")
        #expect(dict["model"] as? String == "opus")
        #expect(!FileManager.default.fileExists(atPath: urls.backupURL.path))
    }

    @Test func removesTheKeyWhenTheUserHadNoStatusLine() throws {
        let scratch = makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let urls = try installedSettings(in: scratch, previous: nil)

        StatuslineUninstall.run(settingsURL: urls.settingsURL, backupURL: urls.backupURL)

        let dict = try settingsDictionary(at: urls.settingsURL)
        #expect(dict["statusLine"] == nil)
        #expect(dict["model"] as? String == "opus")
    }

    /// A backup lost to a store reset or a hand-edit still leaves the dangling
    /// command, which is the harmful part.
    @Test func removesPlumesCommandWithNoBackupToRestoreFrom() throws {
        let scratch = makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let settingsURL = scratch.appending(path: "settings.json")
        let backupURL = scratch.appending(path: "settings.json.plume-backup")

        try write(#"""
        { "statusLine": { "type": "command", "command": "\#(StatuslineUninstall.installedCommand)" }, "model": "opus" }
        """#, to: settingsURL)

        StatuslineUninstall.run(settingsURL: settingsURL, backupURL: backupURL)

        let dict = try settingsDictionary(at: settingsURL)
        #expect(dict["statusLine"] == nil)
        #expect(dict["model"] as? String == "opus")
    }

    @Test func leavesAStatusLinePlumeNeverInstalledAlone() throws {
        let scratch = makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let settingsURL = scratch.appending(path: "settings.json")
        let backupURL = scratch.appending(path: "settings.json.plume-backup")

        try write(#"""
        { "statusLine": { "type": "command", "command": "~/.scripts/.claude/statusline.sh" } }
        """#, to: settingsURL)

        StatuslineUninstall.run(settingsURL: settingsURL, backupURL: backupURL)

        let dict = try settingsDictionary(at: settingsURL)
        let statusLine = try #require(dict["statusLine"] as? [String: Any])
        #expect(statusLine["command"] as? String == "~/.scripts/.claude/statusline.sh")
    }

    @Test func doesNotCreateSettingsWhereNoneExist() throws {
        let scratch = makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let settingsURL = scratch.appending(path: "settings.json")

        StatuslineUninstall.run(
            settingsURL: settingsURL,
            backupURL: scratch.appending(path: "settings.json.plume-backup")
        )

        #expect(!FileManager.default.fileExists(atPath: settingsURL.path))
    }

    /// The second launch must not fight a statusline the user set up in the
    /// meantime, even one that happens to point at the old script path.
    @Test func runsOnceAndThenLeavesTheFileAlone() throws {
        let scratch = makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let suite = UUID().uuidString
        let settings = AppSettings(defaults: try #require(UserDefaults(suiteName: suite)))
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let urls = try installedSettings(in: scratch, previous: "~/.scripts/.claude/statusline.sh")

        StatuslineUninstall.runIfNeeded(
            settings: settings, settingsURL: urls.settingsURL, backupURL: urls.backupURL
        )
        #expect(settings.statuslineCaptureRemoved)

        let reinstalled = try installedSettings(in: scratch, previous: nil)
        StatuslineUninstall.runIfNeeded(
            settings: settings, settingsURL: reinstalled.settingsURL, backupURL: reinstalled.backupURL
        )

        let dict = try settingsDictionary(at: reinstalled.settingsURL)
        let statusLine = try #require(dict["statusLine"] as? [String: Any])
        #expect(statusLine["command"] as? String == StatuslineUninstall.installedCommand)
    }

    @Test func malformedSettingsAreLeftUntouched() throws {
        let scratch = makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let settingsURL = scratch.appending(path: "settings.json")
        let backupURL = scratch.appending(path: "settings.json.plume-backup")

        try write("{ not valid json", to: settingsURL)
        try write(#"{ "statusLine": null }"#, to: backupURL)

        StatuslineUninstall.run(settingsURL: settingsURL, backupURL: backupURL)

        #expect(try String(contentsOf: settingsURL, encoding: .utf8) == "{ not valid json")
    }

    @Test func aStatusLineOfSomeoneElsesIsNotSeenAsInstalled() throws {
        let scratch = makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let settingsURL = scratch.appending(path: "settings.json")
        try write(#"{ "statusLine": { "type": "command", "command": "/usr/local/bin/mine" } }"#, to: settingsURL)

        #expect(StatuslineUninstall.installedStatusLine(in: settingsURL) == nil)
    }
}
