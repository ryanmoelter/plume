import Foundation

/// Where to reach a conversation that Remote Control has published.
struct RemoteControlLink: Equatable {
    let sessionURL: String?
    let connectURL: String?
    let environmentID: String?
    let bridgeSessionID: String?
    let epoch: Int?

    /// The link to show. `connectURL` names an environment, which a session
    /// hosted on this Mac does not have — it arrives as
    /// `https://claude.ai/code?environment=` and goes nowhere. `sessionURL`
    /// addresses the bridge itself and is what works.
    var shareableURL: String? {
        if let environmentID, !environmentID.isEmpty, let connectURL, !connectURL.isEmpty {
            return connectURL
        }
        return sessionURL
    }

    init(payload: [String: JSONValue]) {
        sessionURL = payload["session_url"]?.stringValue
        connectURL = payload["connect_url"]?.stringValue
        environmentID = payload["environment_id"]?.stringValue
        bridgeSessionID = payload["bridge_session_id"]?.stringValue
        epoch = payload["bridge_epoch"]?.doubleValue.map(Int.init)
    }

    init(
        sessionURL: String? = nil,
        connectURL: String? = nil,
        environmentID: String? = nil,
        bridgeSessionID: String? = nil,
        epoch: Int? = nil
    ) {
        self.sessionURL = sessionURL
        self.connectURL = connectURL
        self.environmentID = environmentID
        self.bridgeSessionID = bridgeSessionID
        self.epoch = epoch
    }
}

/// Whether this conversation is published to claude.ai/code, and how to get there.
///
/// Purely in-memory. A bridge belongs to the running `claude` process, so
/// there is nothing here worth persisting — a relaunch starts disconnected.
///
/// Transitions are pure functions so the wire vocabulary can be tested
/// without a process. The vocabulary itself is undocumented and grows between
/// releases, so an unrecognized `state` leaves the current value alone rather
/// than guessing.
enum RemoteControlState: Equatable {
    case disconnected
    case connecting
    case connected(RemoteControlLink)
    case failed(String)

    var link: RemoteControlLink? {
        if case .connected(let link) = self { return link }
        return nil
    }

    var isConnected: Bool { link != nil }

    /// Whether a notice about this state should time out. A failure should
    /// not: it is the only place the reason for it is ever shown.
    var dismissesOnItsOwn: Bool {
        if case .failed = self { return false }
        return true
    }

    /// Folds in a `bridge_state` event.
    ///
    /// The event carries no URLs, so a `connected` keeps whatever link the
    /// control response already supplied. An event from an older bridge is
    /// dropped: a disconnect and reconnect in quick succession would
    /// otherwise let the previous bridge's failure overwrite a live
    /// connection. A missing epoch says nothing about ordering — the first
    /// event of every connect has none — so it never causes a drop.
    func applying(_ bridge: BridgeState) -> RemoteControlState {
        if let incoming = bridge.epoch, let current = link?.epoch, incoming < current {
            return self
        }
        switch bridge.state {
        case "connected", "ready", "reconnected", "attach":
            return .connected(link ?? RemoteControlLink(epoch: bridge.epoch))
        case "failed", "policy_disabled":
            return .failed(bridge.detail ?? "Remote Control disconnected.")
        default:
            return self
        }
    }

    /// Folds in the reply to a `remote_control` request. `enabled` is what
    /// was asked for, since a disable is acknowledged with a bare success
    /// carrying no payload at all.
    static func applying(
        response: ControlResponse,
        enabled: Bool,
        current: RemoteControlState
    ) -> RemoteControlState {
        if response.isError {
            return .failed(response.errorMessage ?? "Remote Control could not be enabled.")
        }
        guard enabled else { return .disconnected }
        let link = RemoteControlLink(payload: response.payload)
        // A `ready` event usually lands before this reply and has already
        // moved the state to `connected` with no link on it.
        return .connected(link)
    }
}
