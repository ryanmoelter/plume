#if DEBUG
import Foundation
import IOKit
import SwiftUI

/// Debug-only readout for testing the lid override by hand: the live
/// `SleepDisabled` value, the thermal level, and the last sleep and wake
/// times. Polls IOKit and sysctl every two seconds while shown, which is why
/// it sits behind `AppSettings.showsKeepAwakeDebugReadout`.
struct KeepAwakeDebugReadout: View {
    let coordinator: KeepAwakeCoordinator

    var body: some View {
        TimelineView(.periodic(from: .now, by: 2)) { context in
            let sample = Sample.take(at: context.date)
            VStack(alignment: .leading, spacing: 2) {
                row("SleepDisabled", sample.sleepDisabled)
                row("Thermal", sample.thermal)
                row("Power", power)
                row("Last sleep", sample.lastSleep)
                row("Last wake", sample.lastWake)
            }
            .font(.caption.monospaced())
            .emphasis(.subtle)
        }
    }

    private var power: String {
        let snapshot = coordinator.powerSnapshot
        let percent = snapshot.percent.map { " \($0)%" } ?? ""
        let charging = snapshot.isCharging ? " charging" : ""
        return "\(snapshot.source)\(percent)\(charging)"
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(label).frame(width: 90, alignment: .leading)
            Text(value)
        }
    }

    private struct Sample {
        var sleepDisabled: String
        var thermal: String
        var lastSleep: String
        var lastWake: String

        static func take(at now: Date) -> Sample {
            Sample(
                sleepDisabled: readSleepDisabled(),
                thermal: describe(ProcessInfo.processInfo.thermalState),
                lastSleep: describe(sysctlTime("kern.sleeptime"), relativeTo: now),
                lastWake: describe(sysctlTime("kern.waketime"), relativeTo: now)
            )
        }

        private static func readSleepDisabled() -> String {
            let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
            guard service != 0 else { return "no IOPMrootDomain" }
            defer { IOObjectRelease(service) }
            let value = IORegistryEntryCreateCFProperty(service, "SleepDisabled" as CFString, kCFAllocatorDefault, 0)
            guard let flag = value?.takeRetainedValue() as? Bool else { return "unset" }
            return flag ? "YES" : "no"
        }

        private static func sysctlTime(_ name: String) -> Date? {
            var value = timeval()
            var size = MemoryLayout<timeval>.size
            guard sysctlbyname(name, &value, &size, nil, 0) == 0, value.tv_sec > 0 else { return nil }
            return Date(timeIntervalSince1970: TimeInterval(value.tv_sec))
        }

        private static func describe(_ date: Date?, relativeTo now: Date) -> String {
            guard let date else { return "never this boot" }
            let clock = date.formatted(date: .omitted, time: .standard)
            let ago = Int(now.timeIntervalSince(date))
            return "\(clock) (\(ago / 60)m \(ago % 60)s ago)"
        }

        private static func describe(_ state: ProcessInfo.ThermalState) -> String {
            switch state {
            case .nominal: "nominal"
            case .fair: "fair"
            case .serious: "serious"
            case .critical: "critical"
            @unknown default: "unknown (\(state.rawValue))"
            }
        }
    }
}
#endif
