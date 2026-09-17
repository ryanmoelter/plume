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

    @Test func themeDirectivesAreStrippedForGhostty() {
        let stripped = GhosttyConfigLoader.strippingThemeDirectives(from: """
        theme = dark:"Lum dark",light:"Lum light"
        font-size = 15
          theme = Nord
        """)

        #expect(!stripped.contains("theme"))
        #expect(stripped.contains("font-size = 15"))
    }

    @Test func strippingKeepsKeysThatMerelyStartWithTheme() {
        let stripped = GhosttyConfigLoader.strippingThemeDirectives(from: """
        theme-ish = keep
        # theme = commented
        """)

        #expect(stripped.contains("theme-ish = keep"))
        #expect(stripped.contains("# theme = commented"))
    }

    // MARK: - config-file expansion

    /// Ghostty loads an included file after the whole file that named it, so
    /// the include wins over a directive set later in the including file.
    @Test func expandConfigAppendsIncludedFileAfterTheIncludingFile() throws {
        let expanded = try #require(GhosttyConfigLoader.expandConfig(rootPath: "/a/config") {
            switch $0 {
            case "/a/config": "config-file = /b/child\nfont-size = 15"
            case "/b/child": "font-size = 20"
            default: nil
            }
        })

        #expect(expanded.lines.map(\.content) == ["font-size = 15", "font-size = 20"])
    }

    @Test func expandConfigDropsTheConfigFileLineItself() throws {
        let expanded = try #require(GhosttyConfigLoader.expandConfig(rootPath: "/a/config") {
            $0 == "/a/config" ? "config-file = /b/child" : "font-size = 20"
        })

        #expect(!expanded.rawContents.contains("config-file"))
    }

    @Test func expandConfigTagsEachLineWithItsOwnFile() throws {
        let expanded = try #require(GhosttyConfigLoader.expandConfig(rootPath: "/a/config") {
            switch $0 {
            case "/a/config": "config-file = /b/child"
            case "/b/child": "theme = Nord"
            default: nil
            }
        })

        #expect(expanded.lines.map(\.sourcePath) == ["/b/child"])
    }

    @Test func expandConfigResolvesRelativeIncludeAgainstTheIncludingFilesDirectory() throws {
        var requested: [String] = []
        _ = GhosttyConfigLoader.expandConfig(rootPath: "/a/config") { path in
            requested.append(path)
            return path == "/a/config" ? "config-file = sub/child" : nil
        }

        #expect(requested.contains("/a/sub/child"))
    }

    /// A nested relative include is relative to *its* file, not to the root —
    /// the distinction this whole expansion exists to get right.
    @Test func expandConfigResolvesNestedRelativeIncludeAgainstItsOwnFile() throws {
        var requested: [String] = []
        _ = GhosttyConfigLoader.expandConfig(rootPath: "/a/config") { path in
            requested.append(path)
            switch path {
            case "/a/config": return "config-file = /b/child"
            case "/b/child": return "config-file = sub/grandchild"
            default: return nil
            }
        }

        #expect(requested.contains("/b/sub/grandchild"))
        #expect(!requested.contains("/a/sub/grandchild"))
    }

    @Test func expandConfigExpandsTildeInIncludePath() {
        var requested: [String] = []
        _ = GhosttyConfigLoader.expandConfig(rootPath: "/a/config") { path in
            requested.append(path)
            return path == "/a/config" ? #"config-file = "~/ghostty-extra""# : nil
        }

        #expect(requested.contains("\(home)/ghostty-extra"))
    }

    @Test func expandConfigSkipsMissingIncludeWithoutFailingTheLoad() throws {
        let expanded = try #require(GhosttyConfigLoader.expandConfig(rootPath: "/a/config") {
            $0 == "/a/config" ? "config-file = /gone\nfont-size = 15" : nil
        })

        #expect(expanded.lines.map(\.content) == ["font-size = 15"])
    }

    @Test func expandConfigSkipsMissingOptionalIncludeMarkedWithQuestionMark() throws {
        let expanded = try #require(GhosttyConfigLoader.expandConfig(rootPath: "/a/config") {
            $0 == "/a/config" ? "config-file = ?/gone\nfont-size = 15" : nil
        })

        #expect(expanded.lines.map(\.content) == ["font-size = 15"])
    }

    @Test func expandConfigReturnsNilWhenTheRootIsUnreadable() {
        #expect(GhosttyConfigLoader.expandConfig(rootPath: "/a/config") { _ in nil } == nil)
    }

    @Test func expandConfigStopsOnDirectSelfReference() throws {
        let expanded = try #require(GhosttyConfigLoader.expandConfig(rootPath: "/a/config") {
            $0 == "/a/config" ? "config-file = /a/config\nfont-size = 15" : nil
        })

        #expect(expanded.lines.map(\.content) == ["font-size = 15"])
    }

    @Test func expandConfigStopsOnIndirectCycle() throws {
        let expanded = try #require(GhosttyConfigLoader.expandConfig(rootPath: "/a/config") {
            switch $0 {
            case "/a/config": "config-file = /b/child\nfont-size = 15"
            case "/b/child": "config-file = /a/config\nfont-size = 20"
            default: nil
            }
        })

        #expect(expanded.lines.map(\.content) == ["font-size = 15", "font-size = 20"])
    }

    @Test func expandConfigCapsRecursionDepth() throws {
        let expanded = try #require(GhosttyConfigLoader.expandConfig(
            rootPath: "/depth/0",
            readFile: { path in
                guard let index = Int(path.replacingOccurrences(of: "/depth/", with: "")) else {
                    return nil
                }
                return "font-size = \(index)\nconfig-file = /depth/\(index + 1)"
            },
            maxDepth: 2
        ))

        #expect(expanded.lines.map(\.content) == ["font-size = 0", "font-size = 1", "font-size = 2"])
    }

    @Test func expandConfigFollowsRepeatedConfigFileDirectivesInOrder() throws {
        let expanded = try #require(GhosttyConfigLoader.expandConfig(rootPath: "/a/config") {
            switch $0 {
            case "/a/config": "config-file = /b/first\nconfig-file = /b/second"
            case "/b/first": "font-size = 1"
            case "/b/second": "font-size = 2"
            default: nil
            }
        })

        #expect(expanded.lines.map(\.content) == ["font-size = 1", "font-size = 2"])
    }

    @Test func winningThemeSourcePathPicksTheIncludedFileWhenItDeclaresThemeLast() throws {
        let expanded = try #require(GhosttyConfigLoader.expandConfig(rootPath: "/a/config") {
            switch $0 {
            case "/a/config": "config-file = /b/child\ntheme = Nord"
            case "/b/child": "theme = Lum dark"
            default: nil
            }
        })

        #expect(GhosttyConfigLoader.winningThemeSourcePath(in: expanded) == "/b/child")
    }

    @Test func winningThemeSourcePathIsNilWithoutAThemeDirective() throws {
        let expanded = try #require(GhosttyConfigLoader.expandConfig(rootPath: "/a/config") { _ in
            "font-size = 15"
        })

        #expect(GhosttyConfigLoader.winningThemeSourcePath(in: expanded) == nil)
    }

    @Test func flattenedContentsForGhosttyStripsThemeAndConfigFileKeys() throws {
        let expanded = try #require(GhosttyConfigLoader.expandConfig(rootPath: "/a/config") {
            switch $0 {
            case "/a/config": "config-file = /b/child\nfont-size = 15"
            case "/b/child": "theme = Nord\nfont-family = Cascadia Code NF"
            default: nil
            }
        })

        let flattened = GhosttyConfigLoader.flattenedContentsForGhostty(expanded)
        #expect(!flattened.contains("theme"))
        #expect(!flattened.contains("config-file"))
        #expect(flattened.contains("font-size = 15"))
        #expect(flattened.contains("font-family = Cascadia Code NF"))
    }

    @Test func resolvedFontFamilyReadsTheRootConfig() throws {
        let expanded = try #require(GhosttyConfigLoader.expandConfig(rootPath: "/a/config") { _ in
            "font-family = Menlo"
        })

        #expect(GhosttyConfigLoader.resolvedFontFamily(in: expanded) == "Menlo")
    }

    /// A config that only redirects via `config-file` is a supported setup —
    /// `font-family` has to resolve from the included file, not just the root.
    @Test func resolvedFontFamilyReadsAnIncludedFile() throws {
        let expanded = try #require(GhosttyConfigLoader.expandConfig(rootPath: "/a/config") {
            switch $0 {
            case "/a/config": "config-file = /b/child"
            case "/b/child": "font-family = Cascadia Code NF"
            default: nil
            }
        })

        #expect(GhosttyConfigLoader.resolvedFontFamily(in: expanded) == "Cascadia Code NF")
    }

    /// An include applies after the file that named it, so its `font-family`
    /// beats one set earlier in the including file.
    @Test func resolvedFontFamilyPrefersTheIncludedFileWhenDeclaredAfterTheRoot() throws {
        let expanded = try #require(GhosttyConfigLoader.expandConfig(rootPath: "/a/config") {
            switch $0 {
            case "/a/config": "font-family = Menlo\nconfig-file = /b/child"
            case "/b/child": "font-family = Cascadia Code NF"
            default: nil
            }
        })

        #expect(GhosttyConfigLoader.resolvedFontFamily(in: expanded) == "Cascadia Code NF")
    }

    @Test func resolvedFontFamilyUnquotesTheValue() throws {
        let expanded = try #require(GhosttyConfigLoader.expandConfig(rootPath: "/a/config") { _ in
            "font-family = \"Cascadia Code NF\""
        })

        #expect(GhosttyConfigLoader.resolvedFontFamily(in: expanded) == "Cascadia Code NF")
    }

    @Test func resolvedFontFamilyIsNilWithoutADirective() throws {
        let expanded = try #require(GhosttyConfigLoader.expandConfig(rootPath: "/a/config") { _ in
            "font-size = 15"
        })

        #expect(GhosttyConfigLoader.resolvedFontFamily(in: expanded) == nil)
    }
}
