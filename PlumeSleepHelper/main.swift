import Foundation
import IOKit
import os

// The privileged helper behind "Keep awake with the lid closed". launchd starts
// it on demand when Plume connects to its Mach service, and it runs as root
// because `SleepDisabled` on IOPMrootDomain is root-only.
//
// Crash safety is the whole design. The override is written to the live
// registry, never to the persisted power-management preferences, so a reboot
// always clears it. On top of that: the sweep on launch, clearing when the
// client's connection dies, and a lease that expires without heartbeats.

let log = Logger(subsystem: "com.ryanmoelter.Plume.SleepHelper", category: "helper")

let onlyPlumeMayConnect =
    "anchor apple generic and certificate leaf[subject.OU] = \"\(sleepHelperTeamID)\""
    + " and (identifier \"com.ryanmoelter.Plume\" or identifier \"com.ryanmoelter.Plume.debug\")"

enum RootDomain {
    static func read() -> Bool? {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(root) }
        return IORegistryEntryCreateCFProperty(root, "SleepDisabled" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Bool
    }

    static func write(_ disabled: Bool) -> kern_return_t {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != IO_OBJECT_NULL else { return KERN_FAILURE }
        defer { IOObjectRelease(root) }
        return IORegistryEntrySetCFProperty(
            root, "SleepDisabled" as CFString, disabled ? kCFBooleanTrue : kCFBooleanFalse
        )
    }
}

/// One client at a time owns the override. All state lives on `queue`.
final class Lease: @unchecked Sendable {
    static let shared = Lease()
    private let queue = DispatchQueue(label: "com.ryanmoelter.Plume.SleepHelper.lease")
    private var holder: ObjectIdentifier?
    private var watchdog: DispatchSourceTimer?

    func engage(for client: ObjectIdentifier, reply: @escaping (Bool, String?) -> Void) {
        queue.async {
            let kr = RootDomain.write(true)
            let now = RootDomain.read() ?? false
            log.notice("engage from \(client.hashValue): kr=\(kr) now=\(now)")
            if kr == KERN_SUCCESS {
                self.holder = client
                self.armWatchdog()
            }
            reply(now, kr == KERN_SUCCESS ? nil : "IORegistryEntrySetCFProperty returned \(kr)")
        }
    }

    func release(for client: ObjectIdentifier?, reason: String, reply: ((Bool, String?) -> Void)? = nil) {
        queue.async {
            // A client may only release its own lease, but the helper itself
            // (nil client) may release anything.
            guard client == nil || client == self.holder || self.holder == nil else {
                reply?(RootDomain.read() ?? false, "another client holds the override")
                return
            }
            let kr = RootDomain.write(false)
            let now = RootDomain.read() ?? false
            log.notice("release (\(reason)): kr=\(kr) now=\(now)")
            self.holder = nil
            self.watchdog?.cancel()
            self.watchdog = nil
            reply?(now, kr == KERN_SUCCESS ? nil : "IORegistryEntrySetCFProperty returned \(kr)")
        }
    }

    func heartbeat(from client: ObjectIdentifier, reply: @escaping (Bool) -> Void) {
        queue.async {
            guard self.holder == client else {
                reply(false)
                return
            }
            self.armWatchdog()
            reply(true)
        }
    }

    private func armWatchdog() {
        watchdog?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + sleepHelperLeaseTimeout)
        timer.setEventHandler { [weak self] in
            self?.release(for: nil, reason: "lease expired without a heartbeat")
        }
        timer.resume()
        watchdog = timer
    }
}

/// The object each connection talks to. One per connection, so the lease knows
/// who is asking without trusting a caller-supplied identity.
final class ClientSession: NSObject, SleepHelperProtocol {
    let id: ObjectIdentifier

    init(connection: NSXPCConnection) {
        id = ObjectIdentifier(connection)
    }

    func setSleepDisabled(_ disabled: Bool, reply: @escaping (Bool, String?) -> Void) {
        if disabled {
            Lease.shared.engage(for: id, reply: reply)
        } else {
            Lease.shared.release(for: id, reason: "client asked", reply: reply)
        }
    }

    func currentState(reply: @escaping (Bool) -> Void) {
        reply(RootDomain.read() ?? false)
    }

    func heartbeat(reply: @escaping (Bool) -> Void) {
        Lease.shared.heartbeat(from: id, reply: reply)
    }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let session = ClientSession(connection: connection)
        connection.exportedInterface = NSXPCInterface(with: SleepHelperProtocol.self)
        connection.exportedObject = session
        let clientID = session.id
        connection.invalidationHandler = {
            Lease.shared.release(for: clientID, reason: "connection invalidated")
        }
        connection.interruptionHandler = {
            Lease.shared.release(for: clientID, reason: "connection interrupted")
        }
        log.notice("accepted connection from pid \(connection.processIdentifier)")
        connection.resume()
        return true
    }
}

// A helper starting up means nobody holds a lease, whatever the registry says.
Lease.shared.release(for: nil, reason: "launch sweep")

let listener = NSXPCListener(machServiceName: sleepHelperServiceName)
// A malformed requirement raises an Objective-C exception here, which is why
// the string is a constant and never assembled at runtime.
listener.setConnectionCodeSigningRequirement(onlyPlumeMayConnect)
let delegate = ListenerDelegate()
listener.delegate = delegate
listener.resume()
dispatchMain()
