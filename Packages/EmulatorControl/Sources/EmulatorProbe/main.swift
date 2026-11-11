import EmulatorControl
import Foundation

var arguments = CommandLine.arguments.dropFirst().makeIterator()
var iniPath: String?
var postureName: String?
var tap: [Int32]?
while let argument = arguments.next() {
    if argument == "--ini" { iniPath = arguments.next() }
    if argument == "--posture" { postureName = arguments.next() }
    if argument == "--tap" { tap = arguments.next()?.split(separator: ",").compactMap { Int32($0) } }
}
guard let iniPath else {
    FileHandle.standardError.write(Data("usage: EmulatorProbe --ini <path>\n".utf8))
    exit(2)
}

func value(_ key: String, in contents: String) -> String? {
    for line in contents.split(separator: "\n") where line.hasPrefix(key + "=") {
        return String(line.dropFirst(key.count + 1)).trimmingCharacters(in: .whitespaces)
    }
    return nil
}

let contents = try String(contentsOfFile: iniPath, encoding: .utf8)
guard let port = value("grpc.port", in: contents).flatMap(Int.init) else {
    FileHandle.standardError.write(Data("no grpc.port in \(iniPath)\n".utf8))
    exit(1)
}
let connection = EmulatorConnection(
    endpoint: EmulatorEndpoint(port: port, token: value("grpc.token", in: contents))
)
do {
    print(try await connection.status())
    print("posture: \(String(describing: try await connection.posture()))")
    if let postureName, let posture = EmulatorPosture.allCases.first(where: { "\($0)" == postureName }) {
        try await connection.setPosture(posture)
        try await Task.sleep(for: .seconds(2))
        print("posture after set: \(String(describing: try await connection.posture()))")
        print(try await connection.status())
    }
    if let tap, tap.count == 2 {
        try await connection.connect()
        connection.send(.touch([TouchPoint(x: tap[0], y: tap[1], identifier: 0, pressure: 1)]))
        try await Task.sleep(for: .milliseconds(100))
        connection.send(.touch([TouchPoint(x: tap[0], y: tap[1], identifier: 0, pressure: 0)]))
        try await Task.sleep(for: .milliseconds(500))
    }
    for try await frame in connection.frames(maxPixelSize: CGSize(width: 4000, height: 4000)) {
        print("frame \(frame.pixelSize) rotation \(frame.rotation)")
        break
    }
} catch {
    print("probe failed: \(error)")
}
await connection.close()
