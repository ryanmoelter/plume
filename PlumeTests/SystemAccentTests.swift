import Testing
@testable import Plume

struct SystemAccentTests {
    @Test func eachSystemAccentMapsToTheClosestANSIHue() {
        let expected: [Int?: Int?] = [
            nil: 4,  // Multicolor shows blue
            -1: nil, // Graphite
            0: 1,
            1: 3,
            2: 3,
            3: 2,
            4: 4,
            5: 5,
            6: 5,
        ]
        for (value, slot) in expected {
            #expect(SystemAccent.paletteSlot(forAppleAccentColor: value) == slot, "AppleAccentColor \(String(describing: value))")
        }
    }
}
