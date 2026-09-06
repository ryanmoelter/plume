import Foundation
import Testing

@testable import Plume

/// Recognizing `/rc` in the composer, and folding the bridge's wire messages
/// into the state the UI renders.
///
/// The wire shapes here were captured from a live `claude -p` (CLI 2.1.261),
/// not inferred — including that a disconnect is acknowledged with a bare
/// success and that the first event of a connect carries no epoch.
@MainActor
struct RemoteControlTests {
    // MARK: - Composer parsing

    @Test func recognizesBareCommand() {
        #expect(PlumeSlashCommand.parse("/rc") == .remoteControl(name: nil))
        #expect(PlumeSlashCommand.parse("  /rc  ") == .remoteControl(name: nil))
    }

    @Test func recognizesNameArgument() {
        #expect(PlumeSlashCommand.parse("/rc laptop") == .remoteControl(name: "laptop"))
    }

    /// A sentence that merely begins with the command is an ordinary message.
    /// Swallowing it would lose what the user typed.
    @Test func ignoresAnythingLongerThanACommandAndOneArgument() {
        #expect(PlumeSlashCommand.parse("/rc one two") == nil)
    }

    @Test func ignoresNearMisses() {
        #expect(PlumeSlashCommand.parse("/rcx") == nil)
        #expect(PlumeSlashCommand.parse("/RC") == nil)
        #expect(PlumeSlashCommand.parse("tell me about /rc") == nil)
        #expect(PlumeSlashCommand.parse("") == nil)
    }

    @Test func advertisesItselfAsPlumeProvided() {
        #expect(PlumeSlashCommand.all.allSatisfy { $0.isPlumeProvided })
        #expect(PlumeSlashCommand.all.map(\.name) == ["rc"])
    }

    // MARK: - Decoding

    @Test func decodesBridgeState() throws {
        let line = """
        {"type":"system","subtype":"bridge_state","state":"connected","bridge_epoch":2,\
        "uuid":"u","session_id":"s"}
        """
        guard case .bridgeState(let bridge) = try #require(StreamJSONDecoder.decode(line: line)) else {
            Issue.record("expected a bridgeState message")
            return
        }
        #expect(bridge.state == "connected")
        #expect(bridge.epoch == 2)
        #expect(bridge.detail == nil)
    }

    /// The first event of every connect has no epoch, so the field must stay
    /// optional rather than defaulting to something orderable.
    @Test func decodesBridgeStateWithoutAnEpoch() throws {
        let line = #"{"type":"system","subtype":"bridge_state","state":"ready","uuid":"u"}"#
        guard case .bridgeState(let bridge) = try #require(StreamJSONDecoder.decode(line: line)) else {
            Issue.record("expected a bridgeState message")
            return
        }
        #expect(bridge.state == "ready")
        #expect(bridge.epoch == nil)
    }

    @Test func leavesOtherSystemSubtypesUnknown() throws {
        let line = #"{"type":"system","subtype":"background_tasks_changed","tasks":[]}"#
        guard case .unknown(let type) = try #require(StreamJSONDecoder.decode(line: line)) else {
            Issue.record("expected an unknown message")
            return
        }
        #expect(type == "system")
    }

    @Test func decodesAnErrorControlResponse() throws {
        let line = """
        {"type":"control_response","response":{"subtype":"error","request_id":"plume-2",\
        "error":"Remote Control cannot be enabled from inside a remote session"}}
        """
        guard case .controlResponse(let response) = try #require(StreamJSONDecoder.decode(line: line)) else {
            Issue.record("expected a controlResponse message")
            return
        }
        #expect(response.isError)
        #expect(response.errorMessage == "Remote Control cannot be enabled from inside a remote session")
    }

    // MARK: - Encoding

    @Test func encodesEnableWithAName() throws {
        let line = try #require(StreamJSONEncoder.remoteControl(
            enabled: true,
            name: "laptop",
            requestID: "plume-3"
        ))
        let request = try requestBody(in: line)
        #expect(request["subtype"]?.stringValue == "remote_control")
        #expect(request["enabled"]?.boolValue == true)
        #expect(request["name"]?.stringValue == "laptop")
    }

    /// Sending a work secret selects the worker-credential path, which needs
    /// a session to reattach to and is refused without one.
    @Test func encodesNoNameAndNoCredentials() throws {
        let line = try #require(StreamJSONEncoder.remoteControl(
            enabled: false,
            name: nil,
            requestID: "plume-4"
        ))
        let request = try requestBody(in: line)
        #expect(request["enabled"]?.boolValue == false)
        #expect(request["name"] == nil)
        #expect(request["work_secret"] == nil)
        #expect(request["reattach_session_id"] == nil)
    }

    // MARK: - State transitions

    @Test func connectsFromTheControlResponse() {
        let state = RemoteControlState.applying(
            response: successResponse,
            enabled: true,
            current: .connecting
        )
        #expect(state.link?.sessionURL == "https://claude.ai/code/session_01A")
        #expect(state.link?.epoch == 1)
    }

    /// `connect_url` names an environment a locally hosted session does not
    /// have, so it arrives empty and `session_url` is the link that works.
    @Test func prefersTheSessionURLWhenThereIsNoEnvironment() {
        let link = RemoteControlState.applying(
            response: successResponse,
            enabled: true,
            current: .connecting
        ).link
        #expect(link?.shareableURL == "https://claude.ai/code/session_01A")
    }

    @Test func prefersTheConnectURLWhenAnEnvironmentIsNamed() {
        let link = RemoteControlLink(
            sessionURL: "https://claude.ai/code/session_01A",
            connectURL: "https://claude.ai/code?environment=env_1",
            environmentID: "env_1"
        )
        #expect(link.shareableURL == "https://claude.ai/code?environment=env_1")
    }

    /// A disable is acknowledged with a bare success carrying no payload, so
    /// what was asked for is the only thing that says what happened.
    @Test func disconnectsOnABarePayload() {
        let response = ControlResponse(
            requestID: "plume-5",
            subtype: "success",
            payload: [:],
            errorMessage: nil
        )
        let state = RemoteControlState.applying(response: response, enabled: false, current: .connected(link))
        #expect(state == .disconnected)
    }

    @Test func failsOnAnErrorResponse() {
        let response = ControlResponse(
            requestID: "plume-6",
            subtype: "error",
            payload: [:],
            errorMessage: "Remote Control initialization failed"
        )
        let state = RemoteControlState.applying(response: response, enabled: true, current: .connecting)
        #expect(state == .failed("Remote Control initialization failed"))
    }

    /// A `bridge_state` event carries no URLs, so it must not cost the state
    /// the link the control response supplied.
    @Test func keepsTheLinkAcrossABridgeEvent() {
        let state = RemoteControlState.connected(link)
            .applying(BridgeState(state: "reconnected", detail: nil, epoch: 1))
        #expect(state.link?.sessionURL == link.sessionURL)
    }

    @Test func failsOnAFailedBridgeEvent() {
        let state = RemoteControlState.connected(link)
            .applying(BridgeState(state: "policy_disabled", detail: "Disabled by policy", epoch: 1))
        #expect(state == .failed("Disabled by policy"))
    }

    /// A disconnect and reconnect in quick succession must not let the old
    /// bridge's failure land on the new one.
    @Test func ignoresAStaleEpoch() {
        let current = RemoteControlState.connected(RemoteControlLink(sessionURL: "u", epoch: 2))
        let state = current.applying(BridgeState(state: "failed", detail: "gone", epoch: 1))
        #expect(state == current)
    }

    /// The first event of a connect has no epoch, which says nothing about
    /// ordering and must not be read as stale.
    @Test func acceptsAnEventWithNoEpoch() {
        let state = RemoteControlState.connecting
            .applying(BridgeState(state: "ready", detail: nil, epoch: nil))
        #expect(state.isConnected)
    }

    /// A toast saying "it worked" is safe to miss. One saying why it didn't
    /// is the only place that reason appears.
    @Test func onlyAFailureOutlastsItsNotice() {
        #expect(RemoteControlState.connected(link).dismissesOnItsOwn)
        #expect(RemoteControlState.connecting.dismissesOnItsOwn)
        #expect(RemoteControlState.disconnected.dismissesOnItsOwn)
        #expect(!RemoteControlState.failed("nope").dismissesOnItsOwn)
    }

    @Test func leavesAnUnrecognizedBridgeStateAlone() {
        let current = RemoteControlState.connected(link)
        #expect(current.applying(BridgeState(state: "state_change", detail: nil, epoch: 1)) == current)
    }

    // MARK: - Fixtures

    private var link: RemoteControlLink {
        RemoteControlLink(
            sessionURL: "https://claude.ai/code/session_01A",
            connectURL: "https://claude.ai/code?environment=",
            environmentID: "",
            bridgeSessionID: "cse_01A",
            epoch: 1
        )
    }

    private var successResponse: ControlResponse {
        ControlResponse(
            requestID: "plume-2",
            subtype: "success",
            payload: [
                "session_url": .string("https://claude.ai/code/session_01A"),
                "connect_url": .string("https://claude.ai/code?environment="),
                "environment_id": .string(""),
                "bridge_epoch": .number(1),
                "bridge_session_id": .string("cse_01A")
            ],
            errorMessage: nil
        )
    }

    private func requestBody(in line: String) throws -> [String: JSONValue] {
        let root = try JSONDecoder().decode(
            [String: JSONValue].self,
            from: try #require(line.data(using: .utf8))
        )
        return try #require(root["request"]?.objectValue)
    }
}
