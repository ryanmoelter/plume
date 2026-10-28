import Foundation
import ScrcpyControl

// Mirrors a device for a few seconds and reports what arrived; injects no input.
// Usage: ScrcpyProbe <adb> <serial> <scrcpy-server> <version> [seconds]
let arguments = CommandLine.arguments
guard arguments.count >= 5 else {
    FileHandle.standardError.write(Data("usage: ScrcpyProbe <adb> <serial> <scrcpy-server> <version> [seconds]\n".utf8))
    exit(2)
}
let seconds = arguments.count > 5 ? Double(arguments[5]) ?? 3 : 3

let connection = ScrcpyConnection(
    adbURL: URL(fileURLWithPath: arguments[1]),
    serial: arguments[2],
    jarURL: URL(fileURLWithPath: arguments[3]),
    version: arguments[4]
)

do {
    let start = ContinuousClock.now
    let (name, size) = try await connection.connect()
    print("connected in \(ContinuousClock.now - start): device=\(name) size=\(Int(size.width))x\(Int(size.height))")

    let counter = Task {
        var count = 0
        var first: ScrcpyFrame?
        var last: ScrcpyFrame?
        do {
            for try await frame in connection.frames() {
                count += 1
                if first == nil {
                    first = frame
                    print("first frame after \(ContinuousClock.now - start): \(Int(frame.pixelSize.width))x\(Int(frame.pixelSize.height)) iosurface=\(frame.surface != nil)")
                }
                last = frame
            }
        } catch {
            print("frames ended: \(error)")
        }
        return (count, last)
    }
    try await Task.sleep(for: .seconds(seconds))
    await connection.close()
    let (count, last) = await counter.value
    print("decoded \(count) frames; last seq=\(last?.seq ?? 0) videoSize=\(last.map { "\(Int($0.videoSize.width))x\(Int($0.videoSize.height))" } ?? "-")")
} catch {
    print("failed: \(error)")
    await connection.close()
    exit(1)
}
