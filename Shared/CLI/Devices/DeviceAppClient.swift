import Foundation

/// The app `plume devices` asks to show and reserve devices. A lease names the socket of the app
/// that owns its tab, so every request names its socket.
nonisolated protocol DeviceAppClient: AnyObject {
    /// Throws when the app can't be reached; a refusal is a reply with `ok` false.
    func send(_ request: CLIRequest, to socket: String) throws -> CLIResponse
}

nonisolated final class SocketDeviceAppClient: DeviceAppClient {
    /// The app answers on its main queue, late when busy.
    static let replyTimeout: TimeInterval = 30
    /// The app answers an extension only once Device Streaming has, which can take 30 seconds.
    static let extendReplyTimeout: TimeInterval = 60

    func send(_ request: CLIRequest, to socket: String) throws -> CLIResponse {
        let timeout = if case .extendDevice = request { Self.extendReplyTimeout } else { Self.replyTimeout }
        return try CLISocket.send(request, to: socket, replyTimeout: timeout)
    }
}
