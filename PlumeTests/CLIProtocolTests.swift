import Foundation
import Testing

@testable import Plume

/// Requests and responses survive the NDJSON line codec unchanged, one compact
/// line each, and the line buffer reassembles lines split across reads.
struct CLIProtocolTests {
    @Test(arguments: [
        CLIRequest.ping,
        .notify(.init(tabID: UUID(), title: "Done; really", body: "line\nbreak")),
        .newTab(.init(taskID: UUID(), directory: "/tmp/a b", select: true)),
        .newTab(.init(taskID: UUID(), directory: nil, select: false)),
        .newTask(.init(worktreePath: "/repo/.plume/worktrees/x", tabID: UUID(), select: false)),
        .openSettings(.init(section: "projects")),
        .openSettings(.init(section: nil)),
    ])
    func requestsRoundTrip(_ request: CLIRequest) throws {
        let line = try CLILineCodec.encode(request)
        #expect(line.last == 0x0A)
        #expect(line.dropLast().contains(0x0A) == false)
        #expect(try CLILineCodec.decode(CLIRequest.self, from: line.dropLast()) == request)
    }

    @Test func aRequestNamesItsCommand() throws {
        let line = try CLILineCodec.encode(CLIRequest.newTab(.init(taskID: UUID(), directory: nil, select: false)))
        let json = try JSONSerialization.jsonObject(with: line) as? [String: Any]
        #expect(json?["command"] as? String == "tab.new")
    }

    @Test func anUnknownCommandFailsToDecode() {
        #expect(throws: DecodingError.self) {
            try CLILineCodec.decode(CLIRequest.self, from: Data(#"{"command":"launch"}"#.utf8))
        }
    }

    @Test func responsesRoundTripAndOmitUnusedFields() throws {
        var response = CLIResponse.success
        response.tabID = UUID()
        let line = try CLILineCodec.encode(response)
        #expect(try CLILineCodec.decode(CLIResponse.self, from: line.dropLast()) == response)

        let failure = try CLILineCodec.encode(CLIResponse.failure("nope"))
        #expect(String(decoding: failure, as: UTF8.self) == #"{"error":"nope","ok":false}"# + "\n")
    }

    @Test func theBufferReassemblesSplitLines() {
        var buffer = CLILineCodec.Buffer()
        buffer.append(Data("{\"a\":1}\n{\"b\"".utf8))
        #expect(buffer.nextLine() == Data("{\"a\":1}".utf8))
        #expect(buffer.nextLine() == nil)
        buffer.append(Data(":2}\n".utf8))
        #expect(buffer.nextLine() == Data("{\"b\":2}".utf8))
        #expect(buffer.nextLine() == nil)
    }
}

/// The socket sits in the data directory's `run` directory unless that path
/// overflows `sun_path`, and `PLUME_SOCKET` overrides it for the tool.
struct CLISocketPathTests {
    @Test func aShortDataDirectoryHoldsTheSocket() {
        #expect(CLISocket.path(applicationSupport: "/Users/me/Library/Application Support/Plume") ==
            "/Users/me/Library/Application Support/Plume/run/cli.sock")
    }

    @Test func aLongDataDirectoryFallsBackToAPrivateTmpDirectory() {
        let long = "/Users/me/" + String(repeating: "deep/", count: 25)
        let other = "/Users/me/" + String(repeating: "dope/", count: 25)
        let path = CLISocket.path(applicationSupport: long, uid: 501)
        #expect(path.hasPrefix("/tmp/plume-501/cli-"))
        #expect(path.hasSuffix(".sock"))
        #expect(path.utf8.count <= CLISocket.maxPathLength)
        #expect(path == CLISocket.path(applicationSupport: long, uid: 501))
        #expect(path != CLISocket.path(applicationSupport: other, uid: 501))
    }

    @Test func theEnvironmentOverridesTheDefault() {
        #expect(CLISocket.resolvedPath(environment: ["PLUME_SOCKET": "/tmp/x.sock"]) == "/tmp/x.sock")
        #expect(CLISocket.resolvedPath(environment: [:])?.hasSuffix("/Library/Application Support/Plume/run/cli.sock") == true)
    }

    /// A tab whose app exported no socket must not reach whichever Plume owns
    /// the release socket instead.
    @Test func aTabWithNoSocketReachesNoApp() {
        let tabID = UUID().uuidString
        #expect(CLISocket.resolvedPath(environment: ["PLUME_TAB_ID": tabID]) == nil)
        #expect(CLISocket.resolvedPath(environment: ["PLUME_TASK_ID": tabID]) == nil)
        #expect(CLISocket.resolvedPath(environment: ["PLUME_TAB_ID": tabID, "PLUME_SOCKET": "/tmp/x.sock"]) == "/tmp/x.sock")
    }
}

/// Presence reads locked first, then asleep only when every display sleeps.
struct PresenceTests {
    private let awake = Presence.Display(id: 1, asleep: false)
    private let asleep = Presence.Display(id: 2, asleep: true)

    @Test func anAwakeDisplayUnlockedIsAwake() {
        #expect(Presence.classify(displays: [asleep, awake], locked: false) == .awake)
    }

    @Test func everyDisplayAsleepIsAsleep() {
        #expect(Presence.classify(displays: [asleep, asleep], locked: false) == .asleep)
    }

    @Test func noDisplayAtAllIsAsleep() {
        #expect(Presence.classify(displays: [], locked: false) == .asleep)
    }

    @Test func aLockedScreenIsLockedWhateverTheDisplays() {
        #expect(Presence.classify(displays: [awake], locked: true) == .locked)
        #expect(Presence.classify(displays: [asleep], locked: true) == .locked)
    }

    @Test func theJSONReportCarriesEveryReading() throws {
        let line = try CLILineCodec.encode(Presence.report(displays: [awake], locked: false))
        #expect(String(decoding: line, as: UTF8.self) ==
            #"{"displays":[{"asleep":false,"id":1}],"locked":false,"state":"awake"}"# + "\n")
    }
}
