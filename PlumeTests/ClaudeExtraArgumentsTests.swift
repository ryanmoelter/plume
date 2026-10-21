import Testing
import Foundation
@testable import Plume

struct ClaudeExtraArgumentsTests {
    private func split(_ string: String) throws -> [String] {
        try ClaudeExtraArguments.split(string, homeDirectory: "/Users/me")
    }

    @Test func splitsOnWhitespace() throws {
        #expect(try split("  --model opus\t--verbose\n") == ["--model", "opus", "--verbose"])
    }

    @Test func emptyStringHasNoArguments() throws {
        #expect(try split("") == [])
        #expect(try split("   ") == [])
    }

    @Test func singleQuotesKeepEverythingLiteral() throws {
        #expect(try split(#"--append-system-prompt 'be "brief" \n $HOME'"#)
            == ["--append-system-prompt", #"be "brief" \n $HOME"#])
    }

    @Test func doubleQuotesHonourOnlyShellEscapes() throws {
        #expect(try split(#""a \"b\" \\ \$c \d""#) == [#"a "b" \ $c \d"#])
    }

    @Test func backslashEscapesOutsideQuotes() throws {
        #expect(try split(#"--add-dir /a\ b \'x"#) == ["--add-dir", "/a b", "'x"])
    }

    @Test func adjacentQuotedPiecesJoinIntoOneWord() throws {
        #expect(try split(#"--x=a'b c'"d""#) == ["--x=ab cd"])
    }

    @Test func emptyQuotesAreAnEmptyArgument() throws {
        #expect(try split("--x '' y") == ["--x", "", "y"])
    }

    @Test func backslashNewlineContinuesTheLine() throws {
        #expect(try split("--model \\\nopus") == ["--model", "opus"])
    }

    @Test func leadingTildeExpandsToHome() throws {
        #expect(try split("--add-dir ~/shared ~") == ["--add-dir", "/Users/me/shared", "/Users/me"])
    }

    @Test func quotedOrEmbeddedTildeStaysLiteral() throws {
        #expect(try split("'~/a' \"~\" a~b ~other --x=~/y") == ["~/a", "~", "a~b", "~other", "--x=~/y"])
    }

    @Test func shellSyntaxIsNeverEvaluated() throws {
        #expect(try split("$(id) `id` ; rm * && $HOME") == ["$(id)", "`id`", ";", "rm", "*", "&&", "$HOME"])
    }

    @Test func unterminatedQuotesFail() {
        #expect(throws: ClaudeExtraArguments.ParseError.unterminatedQuote) { try split("--x 'abc") }
        #expect(throws: ClaudeExtraArguments.ParseError.unterminatedQuote) { try split(#"--x "abc"#) }
        #expect(throws: ClaudeExtraArguments.ParseError.trailingBackslash) { try split(#"--x \"#) }
    }

    @Test func aParseErrorPassesNothing() {
        let resolved = ClaudeExtraArguments("--model opus 'oops")
        #expect(resolved.arguments == [])
        #expect(resolved.parseError == .unterminatedQuote)
    }

    @Test func unreservedFlagsPassThrough() {
        let resolved = ClaudeExtraArguments("--model opus --add-dir /a /b --verbose", homeDirectory: "/h")
        #expect(resolved.arguments == ["--model", "opus", "--add-dir", "/a", "/b", "--verbose"])
        #expect(resolved.ignored == [])
    }

    @Test func reservedFlagsAreDroppedWithTheirValues() {
        let resolved = ClaudeExtraArguments(
            "-p --output-format text --model opus --permission-mode plan --settings=/x.json --bare --add-dir /a"
        )
        #expect(resolved.arguments == ["--model", "opus", "--add-dir", "/a"])
        #expect(resolved.ignored == [
            "-p", "--output-format", "text", "--permission-mode", "plan", "--settings=/x.json", "--bare"
        ])
    }

    @Test func optionalValueFlagsTakeOnlyANonFlagWord() {
        #expect(ClaudeExtraArguments("--resume abc --verbose").arguments == ["--verbose"])
        #expect(ClaudeExtraArguments("--resume --verbose").arguments == ["--verbose"])
        #expect(ClaudeExtraArguments("-r").ignored == ["-r"])
    }

    @Test func shortClustersWithAReservedLetterAreDropped() {
        let resolved = ClaudeExtraArguments("-pc -d")
        #expect(resolved.arguments == ["-d"])
        #expect(resolved.ignored == ["-pc"])
    }

    @Test func everythingAfterADoubleDashIsDropped() {
        let resolved = ClaudeExtraArguments("--verbose -- do something")
        #expect(resolved.arguments == ["--verbose"])
        #expect(resolved.ignored == ["--", "do", "something"])
    }

    @Test func extraArgumentsLeadTheHeadlessCommand() {
        let arguments = HeadlessCommand.arguments(
            resumeSessionID: nil,
            permissionMode: .plan,
            settingsPath: nil,
            model: .opus,
            extraArguments: ["--add-dir", "/a", "--model", "sonnet"]
        )
        #expect(Array(arguments.prefix(5)) == ["claude", "--add-dir", "/a", "--model", "sonnet"])
        #expect(arguments.lastIndex(of: "--model")! > 4)
        #expect(arguments[5] == "-p")
    }

    /// The words the user typed reach `claude` exactly, through the real
    /// login-shell wrap, with nothing in them evaluated.
    @Test func parsedArgumentsSurviveTheLoginShellVerbatim() throws {
        let typed = #"--append-system-prompt "it's \"quoted\" $(touch /tmp/plume-pwned)" --add-dir '/a b' x\;y"#
        let resolved = ClaudeExtraArguments(typed)
        #expect(resolved.arguments == [
            "--append-system-prompt", #"it's "quoted" $(touch /tmp/plume-pwned)"#, "--add-dir", "/a b", "x;y"
        ])
        // `printf` stands in for `claude`, so the assertion covers the real wrap.
        let command = LoginShellCommand.wrap(arguments: ["printf", "%s\\n"] + resolved.arguments)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let words = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
        #expect(words == resolved.arguments)
        #expect(!FileManager.default.fileExists(atPath: "/tmp/plume-pwned"))
    }
}

@MainActor
struct ClaudeExtraArgumentsSettingTests {
    @Test func persistsAcrossReloads() {
        let suite = "ClaudeExtraArgumentsSettingTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AppSettings(defaults: defaults, domainName: suite)
        #expect(settings.claudeExtraArgumentsText == "")
        settings.claudeExtraArgumentsText = "--model opus"

        let reloaded = AppSettings(defaults: defaults, domainName: suite)
        #expect(reloaded.claudeExtraArgumentsText == "--model opus")
        #expect(reloaded.claudeExtraArguments.arguments == ["--model", "opus"])
    }
}
