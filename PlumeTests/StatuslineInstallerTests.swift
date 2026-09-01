import Testing
import Foundation
@testable import Plume

struct StatuslineInstallerTests {
    private func makeScratchDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "StatuslineInstallerTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ json: String, to url: URL) throws {
        try json.write(to: url, atomically: true, encoding: .utf8)
    }

    @Test func previewDoesNotWriteAnything() throws {
        let scratch = makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let settingsURL = scratch.appending(path: "settings.json")

        let preview = StatuslineInstaller.preview(settingsURL: settingsURL)

        // JSONSerialization escapes "/" as "\/" in its pretty-printed output.
        let escapedCommand = StatuslineInstaller.pluginCommand.replacingOccurrences(of: "/", with: "\\/")
        #expect(preview.contains(escapedCommand))
        #expect(!FileManager.default.fileExists(atPath: settingsURL.path))
    }

    @Test func installReplacesStatusLineAndBacksUpThePrevious() throws {
        let scratch = makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let settingsURL = scratch.appending(path: "settings.json")
        let backupURL = scratch.appending(path: "settings.json.plume-backup")

        try write(#"""
        { "statusLine": { "type": "command", "command": "~/.scripts/.claude/statusline.sh", "padding": 0 }, "other": true }
        """#, to: settingsURL)

        let previous = try StatuslineInstaller.install(settingsURL: settingsURL, backupURL: backupURL)
        #expect(previous?.command == "~/.scripts/.claude/statusline.sh")

        let data = try Data(contentsOf: settingsURL)
        let dict = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let statusLine = try #require(dict["statusLine"] as? [String: Any])
        #expect(statusLine["command"] as? String == StatuslineInstaller.pluginCommand)
        #expect(dict["other"] as? Bool == true)

        #expect(FileManager.default.fileExists(atPath: backupURL.path))
        #expect(StatuslineInstaller.isAlreadyInstalled(settingsURL: settingsURL))
    }

    @Test func installIsIdempotentAgainstAnAlreadyInstalledStatusLine() throws {
        let scratch = makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let settingsURL = scratch.appending(path: "settings.json")
        let backupURL = scratch.appending(path: "settings.json.plume-backup")

        try write(#"""
        { "statusLine": { "type": "command", "command": "\#(StatuslineInstaller.pluginCommand)", "padding": 0 } }
        """#, to: settingsURL)

        let previous = try StatuslineInstaller.install(settingsURL: settingsURL, backupURL: backupURL)

        // No backup created — chaining to itself would be a loop, so
        // install() must be a no-op here, just echoing the already-installed value.
        #expect(previous?.command == StatuslineInstaller.pluginCommand)
        #expect(!FileManager.default.fileExists(atPath: backupURL.path))

        let data = try Data(contentsOf: settingsURL)
        let dict = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let statusLine = try #require(dict["statusLine"] as? [String: Any])
        #expect(statusLine["command"] as? String == StatuslineInstaller.pluginCommand)
    }

    @Test func installHandlesAMissingStatusLineKey() throws {
        let scratch = makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let settingsURL = scratch.appending(path: "settings.json")
        let backupURL = scratch.appending(path: "settings.json.plume-backup")

        try write(#"{ "model": "opus" }"#, to: settingsURL)

        let previous = try StatuslineInstaller.install(settingsURL: settingsURL, backupURL: backupURL)
        #expect(previous == nil)

        let data = try Data(contentsOf: settingsURL)
        let dict = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let statusLine = try #require(dict["statusLine"] as? [String: Any])
        #expect(statusLine["command"] as? String == StatuslineInstaller.pluginCommand)
        #expect(dict["model"] as? String == "opus")
    }

    @Test func installThrowsOnMalformedSettingsJSON() throws {
        let scratch = makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let settingsURL = scratch.appending(path: "settings.json")
        let backupURL = scratch.appending(path: "settings.json.plume-backup")

        try write("{ not valid json", to: settingsURL)

        #expect(throws: StatuslineInstaller.InstallerError.settingsUnreadable) {
            try StatuslineInstaller.install(settingsURL: settingsURL, backupURL: backupURL)
        }
    }

    @Test func currentStatusLineReturnsNilOnMalformedJSON() throws {
        let scratch = makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let settingsURL = scratch.appending(path: "settings.json")
        try write("{ not valid json", to: settingsURL)

        #expect(StatuslineInstaller.currentStatusLine(settingsURL: settingsURL) == nil)
    }

    @Test func restorePutsThePreviousStatusLineBack() throws {
        let scratch = makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let settingsURL = scratch.appending(path: "settings.json")
        let backupURL = scratch.appending(path: "settings.json.plume-backup")

        try write(#"""
        { "statusLine": { "type": "command", "command": "~/.scripts/.claude/statusline.sh", "padding": 0 } }
        """#, to: settingsURL)

        try StatuslineInstaller.install(settingsURL: settingsURL, backupURL: backupURL)
        try StatuslineInstaller.restore(settingsURL: settingsURL, backupURL: backupURL)

        let data = try Data(contentsOf: settingsURL)
        let dict = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let statusLine = try #require(dict["statusLine"] as? [String: Any])
        #expect(statusLine["command"] as? String == "~/.scripts/.claude/statusline.sh")
        #expect(!FileManager.default.fileExists(atPath: backupURL.path))
    }

    @Test func restoreRemovesStatusLineWhenNoneExistedBeforeInstall() throws {
        let scratch = makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let settingsURL = scratch.appending(path: "settings.json")
        let backupURL = scratch.appending(path: "settings.json.plume-backup")

        try write(#"{ "model": "opus" }"#, to: settingsURL)

        try StatuslineInstaller.install(settingsURL: settingsURL, backupURL: backupURL)
        try StatuslineInstaller.restore(settingsURL: settingsURL, backupURL: backupURL)

        let data = try Data(contentsOf: settingsURL)
        let dict = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(dict["statusLine"] == nil)
        #expect(dict["model"] as? String == "opus")
    }

    @Test func restoreThrowsWhenNoBackupExists() throws {
        let scratch = makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let settingsURL = scratch.appending(path: "settings.json")
        let backupURL = scratch.appending(path: "settings.json.plume-backup")

        try write(#"{ "model": "opus" }"#, to: settingsURL)

        #expect(throws: StatuslineInstaller.InstallerError.noBackupRecorded) {
            try StatuslineInstaller.restore(settingsURL: settingsURL, backupURL: backupURL)
        }
    }
}
