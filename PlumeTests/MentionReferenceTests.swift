import Foundation
import Testing
@testable import Plume

struct MentionReferenceTests {
    private func kinds(_ text: String) -> [MentionReference.Kind] {
        MentionReference.references(in: text).map(\.kind)
    }

    private func tokens(_ text: String) -> [String] {
        MentionReference.references(in: text).map { (text as NSString).substring(with: $0.range) }
    }

    @Test func eachShapeHasItsKind() {
        #expect(kinds("see @droid-12, #34 and @Plume/UI/Chat.swift") == [
            .linear(identifier: "DROID-12"),
            .pullRequest(number: 34),
            .file(path: "Plume/UI/Chat.swift", isDirectory: false),
        ])
        #expect(kinds("@Plume/UI/ and @/") == [
            .file(path: "Plume/UI", isDirectory: true),
            .file(path: "/", isDirectory: true),
        ])
        #expect(kinds("@~/notes.md") == [.file(path: "~/notes.md", isDirectory: false)])
    }

    @Test func aReferenceNeverStartsInsideAWord() {
        #expect(kinds("me@example.com and issue#12 and C#").isEmpty)
        #expect(tokens("(@DROID-1) [#2]") == ["@DROID-1", "#2"])
    }

    @Test func trailingPunctuationIsNotPartOfTheReference() {
        #expect(tokens("see @README.md. Then #12, or @DROID-3!") == ["@README.md", "#12", "@DROID-3"])
        #expect(tokens("\"@a/b\"") == ["@a/b"])
    }

    @Test func aHashNeedsDigitsThatEndTheToken() {
        #expect(kinds("# Heading").isEmpty)
        #expect(kinds("## Heading").isEmpty)
        #expect(kinds("#12abc").isEmpty)
        #expect(kinds("#").isEmpty)
        #expect(kinds("#123") == [.pullRequest(number: 123)])
        #expect(kinds("#12.") == [.pullRequest(number: 12)])
    }

    @Test func codeAndLinksHideReferences() {
        #expect(kinds("`@DROID-1` and\n```\n#12\n```").isEmpty)
        #expect(kinds("[@DROID-1](https://x.dev) and [x](#12)").isEmpty)
        #expect(kinds("`x` @DROID-2") == [.linear(identifier: "DROID-2")])
    }

    @Test func aQuotedPathKeepsItsSpacesAndEscapes() {
        #expect(kinds(#"see @"My Notes (draft).md" now"#) == [.file(path: "My Notes (draft).md", isDirectory: false)])
        #expect(kinds(#"@"a\"b.txt""#) == [.file(path: #"a"b.txt"#, isDirectory: false)])
        #expect(kinds(#"@"My Docs/""#) == [.file(path: "My Docs", isDirectory: true)])
        #expect(tokens(#"(@"x y")"#) == [#"@"x y""#])
    }

    @Test func anUnclosedOrBrokenQuoteIsNoReference() {
        #expect(kinds(#"@"My Notes"#).isEmpty)
        #expect(kinds("@\"a\nb\"").isEmpty)
        #expect(kinds(#"@"a"b"#).isEmpty)
        #expect(kinds(#"@"""#).isEmpty)
    }

    @Test func filterPrefixesAndBareTriggersAreSkipped() {
        #expect(kinds("@linear:dro @pr: @ @@x #").isEmpty)
    }

    @Test func offsetsAreUTF16() {
        let references = MentionReference.references(in: "🎉 #1")
        #expect(references.map(\.range) == [NSRange(location: 3, length: 2)])
    }

    // MARK: - Tokens

    @Test func aTokenRoundTripsThroughTheParser() {
        let samples: [MentionReference.Kind] = [
            .linear(identifier: "DROID-123"),
            .pullRequest(number: 9),
            .file(path: "Plume/UI/Chat.swift", isDirectory: false),
            .file(path: "Plume/UI", isDirectory: true),
            .file(path: "My Notes (draft).md", isDirectory: false),
            .file(path: #"a"b\c.txt"#, isDirectory: false),
            .file(path: "DROID-12", isDirectory: false),
            .file(path: "ends.", isDirectory: false),
            .file(path: "#hash", isDirectory: false),
        ]
        for kind in samples {
            #expect(kinds("see " + MentionReference.token(for: kind) + " now") == [kind], "\(kind)")
        }
    }

    @Test func onlyAPathThatWouldMisreadIsQuoted() {
        #expect(!MentionReference.needsQuotes("Plume/UI/Chat.swift"))
        #expect(!MentionReference.needsQuotes("~/a-b_c.txt"))
        #expect(MentionReference.needsQuotes("a b"))
        #expect(MentionReference.needsQuotes("a,b"))
        #expect(MentionReference.needsQuotes("DROID-1"))
        #expect(MentionReference.needsQuotes("end."))
    }

    @Test func aCompleteFirstWordIsATokenNotAQuery() {
        #expect(MentionReference.isCompleteToken("DROID-12", trigger: .at))
        #expect(MentionReference.isCompleteToken("a/b,", trigger: .at))
        #expect(!MentionReference.isCompleteToken("droid-", trigger: .at))
        #expect(!MentionReference.isCompleteToken("dro", trigger: .at))
        #expect(MentionReference.isCompleteToken("12", trigger: .hash))
        #expect(!MentionReference.isCompleteToken("lay", trigger: .hash))
    }
}
