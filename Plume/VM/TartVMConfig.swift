import Foundation

/// The `config.json` of a Tart VM directory. `hardwareModel` and `ecid` are base64 of the
/// Virtualization `dataRepresentation`s.
nonisolated struct TartVMConfig: Codable, Equatable, Sendable {
    struct Display: Codable, Equatable, Sendable {
        var width: Int
        var height: Int
    }

    var version: Int
    var os: String
    var arch: String
    var cpuCount: Int
    var cpuCountMin: Int?
    var memorySize: UInt64
    var memorySizeMin: UInt64?
    var macAddress: String
    var display: Display
    var hardwareModel: String
    var ecid: String
    var diskFormat: String?

    static let fileName = "config.json"

    static func parse(_ data: Data) throws -> TartVMConfig {
        try JSONDecoder().decode(TartVMConfig.self, from: data)
    }

    var hardwareModelData: Data? { Data(base64Encoded: hardwareModel) }
    var ecidData: Data? { Data(base64Encoded: ecid) }

    /// Rewrites only `ecid`, keeping every other key, known or not, so a newer Tart's fields survive.
    static func rewritingECID(in data: Data, to ecid: Data) throws -> Data {
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        object["ecid"] = ecid.base64EncodedString()
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }
}
