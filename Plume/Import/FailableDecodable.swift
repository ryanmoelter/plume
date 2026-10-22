import Foundation

/// Swallows its own decode error so one malformed array element never fails
/// the whole array.
nonisolated struct FailableDecodable<T: Decodable>: Decodable {
    let value: T?

    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}
