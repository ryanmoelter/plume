import EmulatorControl
import Foundation

var arguments = CommandLine.arguments.dropFirst().makeIterator()
var iniPath: String?
while let argument = arguments.next() {
    if argument == "--ini" { iniPath = arguments.next() }
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
} catch {
    print("status failed: \(error)")
}
await connection.close()
