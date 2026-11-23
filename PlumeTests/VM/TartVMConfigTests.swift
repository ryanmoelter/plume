import Foundation
import Testing
@testable import Plume

struct TartVMConfigTests {
    /// `plume-base-27`'s config, plus a key a newer Tart might add.
    static let fixture = """
        {
          "arch" : "arm64",
          "cpuCount" : 4,
          "cpuCountMin" : 2,
          "diskFormat" : "asif",
          "display" : { "height" : 1200, "width" : 1920 },
          "ecid" : "YnBsaXN0MDDRAQJURUNJRBM20\\/KBW5dAaAgLEAAAAAAAAAEBAAAAAAAAAAMAAAAAAAAAAAAAAAAAAAAZ",
          "futureKey" : { "nested" : [1, 2] },
          "hardwareModel" : "YnBsaXN0MDDTAQIDBAQFXxAZRGF0YVJlcHJlc2VudGF0aW9uVmVyc2lvbl8QD1BsYXRmb3JtVmVyc2lvbl8QEk1pbmltdW1TdXBwb3J0ZWRPUxACowYHBxANEAAIDys9UlRYWgAAAAAAAAEBAAAAAAAAAAgAAAAAAAAAAAAAAAAAAABc",
          "macAddress" : "1a:68:b0:e1:4a:69",
          "memorySize" : 8589934592,
          "memorySizeMin" : 4294967296,
          "os" : "darwin",
          "version" : 1
        }
        """

    @Test func parsesTartsKeys() throws {
        let config = try TartVMConfig.parse(Data(Self.fixture.utf8))
        #expect(config.version == 1)
        #expect(config.os == "darwin")
        #expect(config.arch == "arm64")
        #expect(config.cpuCount == 4)
        #expect(config.cpuCountMin == 2)
        #expect(config.memorySize == 8_589_934_592)
        #expect(config.memorySizeMin == 4_294_967_296)
        #expect(config.macAddress == "1a:68:b0:e1:4a:69")
        #expect(config.display == .init(width: 1920, height: 1200))
        #expect(config.diskFormat == "asif")
        #expect(config.hardwareModelData != nil)
        #expect(config.ecidData != nil)
    }

    @Test func rewritingTheECIDKeepsEveryOtherKey() throws {
        let original = Data(Self.fixture.utf8)
        let ecid = Data([1, 2, 3, 4])
        let rewritten = try TartVMConfig.rewritingECID(in: original, to: ecid)

        let before = try #require(try JSONSerialization.jsonObject(with: original) as? NSDictionary)
        let after = try #require(try JSONSerialization.jsonObject(with: rewritten) as? NSDictionary)
        #expect(after["ecid"] as? String == ecid.base64EncodedString())
        #expect(Set(after.allKeys as! [String]) == Set(before.allKeys as! [String]))
        for key in before.allKeys as! [String] where key != "ecid" {
            #expect((after[key] as AnyObject).isEqual(before[key]), "\(key)")
        }
        #expect(try TartVMConfig.parse(rewritten).ecidData == ecid)
    }
}
