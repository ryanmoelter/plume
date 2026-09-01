import Testing
import Foundation
@testable import Plume

/// Ordering mirrors `preferredDefaultFilePath()` in ghostty's
/// `src/config/file_load.zig`: Application Support outranks XDG on macOS, and
/// the `config.ghostty` name outranks the legacy `config` within each pair.
struct GhosttyConfigLoaderTests {
    private let home = NSHomeDirectory()

    @Test func applicationSupportOutranksXDG() throws {
        let paths = GhosttyConfigLoader.candidatePaths(environment: [:])
        let appSupport = try #require(paths.firstIndex { $0.contains("Application Support") })
        let xdg = try #require(paths.firstIndex { $0.contains("/.config/ghostty") })
        #expect(appSupport < xdg)
    }

    @Test func newExtensionOutranksLegacyNameInBothPairs() {
        let paths = GhosttyConfigLoader.candidatePaths(environment: [:])
        #expect(paths == [
            "\(home)/Library/Application Support/com.mitchellh.ghostty/config.ghostty",
            "\(home)/Library/Application Support/com.mitchellh.ghostty/config",
            "\(home)/.config/ghostty/config.ghostty",
            "\(home)/.config/ghostty/config",
        ])
    }

    @Test func xdgConfigHomeOverridesTheDefaultLocation() {
        let paths = GhosttyConfigLoader.candidatePaths(environment: ["XDG_CONFIG_HOME": "/custom"])
        #expect(paths.contains("/custom/ghostty/config"))
        #expect(!paths.contains { $0.hasPrefix("\(home)/.config") })
    }

    @Test func emptyXDGConfigHomeFallsBackToDefault() {
        let paths = GhosttyConfigLoader.candidatePaths(environment: ["XDG_CONFIG_HOME": ""])
        #expect(paths.contains("\(home)/.config/ghostty/config"))
    }

    @Test func firstExistingCandidateWinsWithoutMerging() {
        let paths = GhosttyConfigLoader.candidatePaths(environment: [:])
        let legacyAppSupport = paths[1]
        let xdgPath = paths[3]

        let resolved = GhosttyConfigLoader.userConfigPath(environment: [:]) {
            $0 == legacyAppSupport || $0 == xdgPath
        }

        #expect(resolved == legacyAppSupport)
    }

    @Test func missingConfigResolvesToNil() {
        #expect(GhosttyConfigLoader.userConfigPath(environment: [:]) { _ in false } == nil)
    }

    @Test func themesDirectoryIsSiblingOfConfigFile() {
        let path = GhosttyConfigLoader.themesDirectory(forConfigPath: "/tmp/ghostty/config")
        #expect(path == "/tmp/ghostty/themes")
    }

    @Test func themesDirectoryResolvesSymlinksBeforeAppending() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let realConfigDir = tempDir.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: realConfigDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let realConfig = realConfigDir.appendingPathComponent("config")
        try "theme = X".write(to: realConfig, atomically: true, encoding: .utf8)

        let symlinkConfig = tempDir.appendingPathComponent("config")
        try FileManager.default.createSymbolicLink(at: symlinkConfig, withDestinationURL: realConfig)

        let path = GhosttyConfigLoader.themesDirectory(forConfigPath: symlinkConfig.path)
        #expect(path == realConfigDir.appendingPathComponent("themes").path)
    }
}
