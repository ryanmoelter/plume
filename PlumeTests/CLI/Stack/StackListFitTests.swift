import Foundation
import Testing
@testable import Plume

/// `stack list` on a terminal of known width never wraps: branch names
/// narrow, then a line's tail is cut, while tree glyphs and chips keep their
/// width. Piped output, `--json` and an unknown width are never cut.
struct StackListFitTests {
    static let base = "feature/a-really-long-base-branch-name"
    static let tee = "feature/a-really-long-1-teed-child-name"
    static let spine = "feature/a-really-long-2-spine-child-name"
    static let inner = "feature/a-really-long-1-inner-teed-grandchild"
    static let innerSpine = "feature/a-really-long-2-inner-spine-grandchild"
    static let names = [base, spine, tee, inner, innerSpine]

    // The last child in name order continues the spine and the others tee
    // off, so `tee` sits in column 2 and its child `inner` in column 3.
    let git = FakeStackGit(
        tips: ["main": "m0", base: "a1", spine: "b1", tee: "c1", inner: "d1", innerSpine: "e1"],
        ancestors: [
            "m0": [], "a1": ["m0"],
            "b1": ["a1", "m0"], "c1": ["a1", "m0"],
            "d1": ["c1", "a1", "m0"], "e1": ["c1", "a1", "m0"],
        ]
    )
    let branches: StackBranches = [
        base: entry("main", "m0"),
        spine: entry(base, "a1"),
        tee: entry(base, "a1"),
        inner: entry(tee, "c1"),
        innerSpine: entry(tee, "c1"),
    ]
    let console = BufferConsole()

    func lines(_ state: PRState, columns: Int?, git: FakeStackGit? = nil, branches: StackBranches? = nil, current: String? = nil) throws -> [Chip] {
        let branches = branches ?? self.branches
        return try Stack.renderLines(
            stackContext(git ?? self.git, console: console, ui: nerdUI), branches, roots: StackGraph.roots(branches),
            current: current ?? Self.base, prs: [:], prState: state, forgeIcon: nerdUI.github, columns: columns
        )
    }

    /// The tree glyphs, markers and count labels: everything before a row's
    /// first letter.
    func graphPrefix(_ line: String) -> Substring {
        line.prefix { !$0.isLetter }
    }

    @Test func aDeepStackWithLongNamesFitsFiftyColumnsExactly() throws {
        let full = try lines(.loading, columns: nil)
        let fitted = try lines(.loading, columns: 50)
        try #require(full.map(\.width).max()! > 50)
        try #require(fitted.count == full.count)
        #expect(fitted.map(\.width).max() == 50)
        #expect(fitted.map(\.width) == fitted.map { TerminalUI.visibleWidth($0.text) })
        #expect(zip(fitted, full).allSatisfy { graphPrefix($0.text) == graphPrefix($1.text) })
        let deepest = try #require(fitted.first { $0.text.hasPrefix("│ │ │ ● ") })
        #expect(deepest.width == 50)
        #expect(deepest.text.hasPrefix("│ │ │ ● \(Self.inner.prefix(30))"))
        #expect(!deepest.text.contains(Self.inner))

        let chip = nerdUI.loadingChip(forgeIcon: nerdUI.github).text
        let chipped = fitted.filter { $0.text.contains(chip) }
        #expect(chipped.count == Self.names.count)
        #expect(chipped.allSatisfy { $0.text.hasSuffix(chip) })
    }

    @Test func belowTheNameFloorTheLineTailIsCut() throws {
        let fitted = try lines(.loading, columns: 20)
        #expect(fitted.allSatisfy { $0.width <= 20 })
        let node = try #require(fitted.first { $0.text.hasPrefix("│ │ │ ● ") })
        let chip = nerdUI.loadingChip(forgeIcon: nerdUI.github).text
        #expect(node.text.hasPrefix("│ │ │ ● feature…"))
        #expect(node.width == 20)
        #expect(!node.text.hasSuffix(chip))
    }

    @Test func aWideGlyphBranchNameIsCutAtAGrapheme() throws {
        let family = "👨‍👩‍👧"
        let name = String(repeating: family, count: 8) + "日本語-fix"
        let git = FakeStackGit(tips: ["main": "m0", name: "a1"], ancestors: linearHistory("m0", "a1"))
        let fitted = try lines(.loading, columns: 24, git: git, branches: [name: entry("main", "m0")], current: name)
        #expect(fitted.allSatisfy { $0.width <= 24 })
        let node = try #require(fitted.first { $0.text.contains(family) })
        let start = try #require(node.text.range(of: family)).lowerBound
        let end = try #require(node.text.range(of: "…")).lowerBound
        let kept = node.text[start ..< end]
        #expect(Array(name).starts(with: Array(kept)))
        #expect(kept.count < Array(name).count)
        #expect(kept.allSatisfy { $0 == Character(family) })
    }

    @Test func theLiveRedrawRewindsExactlyTheLineCount() throws {
        console.terminalSize = TerminalSize(columns: 50, rows: 100)
        let ctx = stackContext(git, console: console, ui: nerdUI)
        try Stack.printLive(
            ctx, branches, roots: StackGraph.roots(branches), current: Self.base,
            fetch: ScriptedFetchCompletion(true, result: [:]), forgeIcon: nerdUI.github, numberPrefix: "#", live: true
        )
        let lineCount = try lines(.loading, columns: 50).count
        let frames = console.stdout.components(separatedBy: TerminalUI.redrawPrefix(lines: lineCount))
        try #require(frames.count == 2)
        let loading = frames[0].split(separator: "\n")
        #expect(loading.count == lineCount)
        #expect(loading.allSatisfy { TerminalUI.visibleWidth(String($0)) <= 50 })
        #expect(frames[1].split(separator: "\n").allSatisfy { TerminalUI.visibleWidth(String($0)) <= 50 })
    }

    @Test func pipedOutputIsNeverCut() throws {
        console.terminalSize = TerminalSize(columns: 50, rows: 100)
        let ctx = stackContext(git, console: console, ui: nerdUI)
        try Stack.printLive(
            ctx, branches, roots: StackGraph.roots(branches), current: Self.base,
            fetch: ScriptedFetchCompletion(true, result: [:]), forgeIcon: nerdUI.github, numberPrefix: "#", live: false
        )
        let expected = LiveRedraw.text(try lines(.on, columns: nil))
        #expect(console.stdout == expected + "\n")
        #expect(!console.stdout.contains("…"))
    }

    @Test func aTerminalOfUnknownWidthIsNeverCut() throws {
        let ctx = stackContext(git, console: console, ui: nerdUI)
        try Stack.printLive(
            ctx, branches, roots: StackGraph.roots(branches), current: Self.base,
            fetch: nil, forgeIcon: nerdUI.github, numberPrefix: "#", live: true
        )
        #expect(console.stdout == LiveRedraw.text(try lines(.off, columns: nil)) + "\n")
    }

    @Test func jsonIsNeverCut() throws {
        let directory = try makeScratchDirectory() + "/stack"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try StackStateCodec.encode(branches).write(toFile: "\(directory)/branches.json", atomically: true, encoding: .utf8)
        let terminal = BufferConsole(stdoutIsTerminal: true, terminalSize: TerminalSize(columns: 50, rows: 100))
        git.current = Self.base
        try Stack.list(stackContext(git, console: terminal, stateDirectory: directory), ["--json"])
        for name in Self.names { #expect(terminal.stdout.contains("\"name\": \"\(name)\"")) }
        #expect(!terminal.stdout.contains("…"))
    }
}
