import Foundation
import Testing

@testable import Plume

/// `plume routine` parsing, the wire shape of its requests, and how a name
/// picks a routine.
struct RoutineCLITests {
    private func parse(_ arguments: [String]) throws -> CLIInvocation {
        try CLICommandLine.parse(arguments, executableName: "plume")
    }

    @Test func listAndRunParse() throws {
        #expect(try parse(["routine", "list"]) == .routine(.list(json: false)))
        #expect(try parse(["routines", "ls", "--json"]) == .routine(.list(json: true)))
        #expect(try parse(["routine", "run", "Nightly triage"]) == .routine(.run("Nightly triage")))
    }

    @Test func badRoutineArgumentsAreUsageErrors() {
        #expect(throws: CLIUsageError.self) { try parse(["routine"]) }
        #expect(throws: CLIUsageError.self) { try parse(["routine", "run"]) }
        #expect(throws: CLIUsageError.self) { try parse(["routine", "run", "a", "b"]) }
        #expect(throws: CLIUsageError.self) { try parse(["routine", "list", "--yaml"]) }
        #expect(throws: CLIUsageError.self) { try parse(["routine", "delete", "a"]) }
        #expect(throws: CLIUsageError(message: nil, usage: CLICommandLine.routineUsage)) {
            try parse(["routine", "--help"])
        }
    }

    @Test func requestsRoundTrip() throws {
        for request in [CLIRequest.listRoutines, .runRoutine(.init(routine: "Triage"))] {
            let line = try CLILineCodec.encode(request)
            #expect(try CLILineCodec.decode(CLIRequest.self, from: line.dropLast()) == request)
        }
        let json = String(decoding: try CLILineCodec.encode(CLIRequest.runRoutine(.init(routine: "T"))), as: UTF8.self)
        #expect(json == "{\"command\":\"routines.run\",\"params\":{\"routine\":\"T\"}}\n")
    }

    @Test func aNamePicksByIDThenExactNameThenUniquePart() throws {
        let triage = (id: UUID(), name: "Triage")
        let nightly = (id: UUID(), name: "Nightly triage")
        let deps = (id: UUID(), name: "Bump deps")
        let all = [triage, nightly, deps]
        #expect(try RoutineCommands.match(nightly.id.uuidString, among: all) == nightly.id)
        #expect(try RoutineCommands.match("triage", among: all) == triage.id)
        #expect(try RoutineCommands.match("deps", among: all) == deps.id)
        #expect(throws: RoutineCommands.LookupError.ambiguous("ri", ["Triage", "Nightly triage"])) {
            try RoutineCommands.match("ri", among: all)
        }
        #expect(throws: RoutineCommands.LookupError.notFound("lint")) {
            try RoutineCommands.match("lint", among: all)
        }
    }
}
