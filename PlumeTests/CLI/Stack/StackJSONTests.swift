import Foundation
import Testing
@testable import Plume

/// `branches.json` must stay byte-identical to what other copies of `stack`
/// write: `json.dump(indent=2, sort_keys=True)` plus a newline, with
/// `ensure_ascii` escaping. The expected bytes here are that output.
struct StackJSONTests {
    @Test func encodesTheStateFileExactly() {
        let text = StackStateCodec.encode([
            "feat-b": entry("feat-a", "b".repeated(40)),
            "feat-a": entry("main", "a".repeated(40)),
        ])
        #expect(text == """
            {
              "branches": {
                "feat-a": {
                  "base": "\("a".repeated(40))",
                  "parent": "main"
                },
                "feat-b": {
                  "base": "\("b".repeated(40))",
                  "parent": "feat-a"
                }
              },
              "version": 2
            }

            """)
    }

    /// `json.dumps("ryanm/é😀\"\\\t\u{1}")`: `/` stays bare, non-ASCII is a
    /// lowercase `\u` escape, and above U+FFFF a surrogate pair.
    @Test func escapesAsPythonEnsureASCIIDoes() {
        let rendered = StackJSON.string("ryanm/é😀\"\\\t\u{1}\n\r\u{8}\u{C}").rendered()
        #expect(rendered == #""ryanm/\u00e9\ud83d\ude00\"\\\t\u0001\n\r\b\f""#)
    }

    /// Python sorts by code point; Swift's `<` on `String` does not always.
    @Test func sortsKeysByCodePoint() {
        let object = StackJSON.object([
            StackJSONMember("b", .int(1)),
            StackJSONMember("é", .int(2)),
            StackJSONMember("B", .int(3)),
            StackJSONMember("a", .int(4)),
        ])
        #expect(object.rendered(sortKeys: true) == "{\n  \"B\": 3,\n  \"a\": 4,\n  \"b\": 1,\n  \"\\u00e9\": 2\n}")
    }

    @Test func rendersEmptyContainersAndScalarsAsPythonDoes() {
        let value = StackJSON.object([
            StackJSONMember("list", .array([])),
            StackJSONMember("map", .object([])),
            StackJSONMember("null", .null),
            StackJSONMember("yes", .bool(true)),
            StackJSONMember("float", .double(1.5)),
            StackJSONMember("whole", .double(2)),
            StackJSONMember("items", .array([.int(1), .string("x")])),
        ])
        #expect(value.rendered() == """
            {
              "list": [],
              "map": {},
              "null": null,
              "yes": true,
              "float": 1.5,
              "whole": 2.0,
              "items": [
                1,
                "x"
              ]
            }
            """)
    }

    @Test func roundTripsAFileByteForByte() throws {
        let original = """
            {
              "branches": {
                "a": {
                  "base": "m0",
                  "note": "kept \\u00e9",
                  "parent": "main"
                },
                "ryanm/b": {
                  "base": "a1",
                  "parent": "a"
                }
              },
              "version": 2
            }

            """
        let branches = try StackStateCodec.decode(Data(original.utf8))
        #expect(StackStateCodec.encode(Dictionary(uniqueKeysWithValues: branches.map { ($0.name, $0.entry) })) == original)
    }

    @Test func readsCompactJSONAndKeepsUnknownEntryKeys() throws {
        let branches = try StackStateCodec.decode(Data(#"{"version": 2, "branches": {"a": {"parent": "main", "base": "m0", "pr": 7}}}"#.utf8))
        #expect(branches.map(\.name) == ["a"])
        #expect(branches[0].entry.parent == "main")
        #expect(branches[0].entry.base == "m0")
        #expect(branches[0].entry.extra == [StackJSONMember("pr", .int(7))])
    }

    @Test func aMissingVersionIsVersionOne() throws {
        let branches = try StackStateCodec.decode(Data(#"{"branches": {"a": {"parent": "main", "base": "m0"}}}"#.utf8))
        #expect(branches.count == 1)
    }

    @Test func refusesANewerVersion() {
        #expect(throws: StackStateCodec.DecodeError.tooNew(3)) {
            try StackStateCodec.decode(Data(#"{"version": 3, "branches": {}}"#.utf8))
        }
    }

    @Test func unreadableShapesAreUnreadable() {
        for text in [
            "not json",
            "[]",
            #"{"version": 2}"#,
            #"{"version": 2, "branches": []}"#,
            #"{"version": 2, "branches": {"a": {"parent": "main"}}}"#,
            #"{"version": 2, "branches": {"a": "main"}}"#,
        ] {
            #expect(throws: StackStateCodec.DecodeError.self, "\(text)") {
                try StackStateCodec.decode(Data(text.utf8))
            }
        }
    }

    @Test func parsesEscapesAndNumbers() throws {
        let value = try StackJSON.parse(Data(#"{"s": "a\u00e9\ud83d\ude00\/", "i": -12, "d": 1e3, "n": null, "t": false}"#.utf8))
        #expect(value["s"] == .string("aé😀/"))
        #expect(value["i"] == .int(-12))
        #expect(value["d"] == .double(1000))
        #expect(value["n"] == .null)
        #expect(value["t"] == .bool(false))
    }
}

extension String {
    func repeated(_ count: Int) -> String {
        String(repeating: self, count: count)
    }
}
