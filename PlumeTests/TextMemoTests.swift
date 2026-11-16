import Foundation
import Testing
@testable import Plume

struct TextMemoTests {
    @Test func canonicallyEquivalentTextsAreDifferentKeys() {
        let memo = TextMemo<Int>()
        let composed = "caf\u{E9}"
        let decomposed = "cafe\u{301}"
        #expect(composed == decomposed)
        #expect(memo.value(for: composed) { ($0 as NSString).length } == 4)
        #expect(memo.value(for: decomposed) { ($0 as NSString).length } == 5)
    }

    @Test func aBridgedTextFindsTheNativeOne() {
        let memo = TextMemo<Int>()
        var computed = 0
        _ = memo.value(for: "- a\n- b") { _ in computed += 1; return 0 }
        let bridged = NSMutableString(string: "- a\n- b") as String
        _ = memo.value(for: bridged) { _ in computed += 1; return 0 }
        #expect(computed == 1)
    }
}
