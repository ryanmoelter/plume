import Darwin
import Foundation
import Observation

/// Tracks emulators already running, whoever started them. Idle until retained.
@MainActor @Observable
final class EmulatorDiscovery {
    static let shared = EmulatorDiscovery()

    private(set) var running: [RunningEmulator] = []

    @ObservationIgnored private var retainCount = 0
    @ObservationIgnored private var sources: [DispatchSourceFileSystemObject] = []
    @ObservationIgnored private var timer: DispatchSourceTimer?
    @ObservationIgnored private var debounce: Task<Void, Never>?
    @ObservationIgnored private let directories: [URL]

    init(directories: [URL] = EmulatorScanner.runningDirectories()) {
        self.directories = directories
    }

    func retain() {
        retainCount += 1
        guard retainCount == 1 else { return }
        startWatching()
        scheduleRescan(after: .zero)
    }

    func release() {
        guard retainCount > 0 else { return }
        retainCount -= 1
        guard retainCount == 0 else { return }
        stopWatching()
    }

    func refresh() async {
        let directories = directories
        let found = await Task.detached { EmulatorScanner.scanAll(directories: directories) }.value
        if found != running {
            EmulatorLog.info("running emulators: \(found.map { "\($0.avdID) (pid \($0.pid))" })")
            running = found
        }
    }

    private func scheduleRescan(after delay: Duration) {
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, self.retainCount > 0 else { return }
            await self.refresh()
        }
    }

    private func startWatching() {
        for directory in directories {
            var watched = directory
            while !FileManager.default.fileExists(atPath: watched.path), watched.path != "/" {
                watched = watched.deletingLastPathComponent()
            }
            let descriptor = open(watched.path, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor, eventMask: [.write, .delete, .rename], queue: .main
            )
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.scheduleRescan(after: .milliseconds(200)) }
            }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            sources.append(source)
        }
        // Covers a missing directory, whose ancestor sees only coarse changes, and a pid dying without touching the file.
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.scheduleRescan(after: .zero) }
        }
        timer.resume()
        self.timer = timer
    }

    private func stopWatching() {
        sources.forEach { $0.cancel() }
        sources = []
        timer?.cancel()
        timer = nil
        debounce?.cancel()
        debounce = nil
    }
}
