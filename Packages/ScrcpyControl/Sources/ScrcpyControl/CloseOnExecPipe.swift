import Foundation

extension Pipe {
    /// `Process` leaves its pipes inheritable, and libghostty forks every
    /// terminal's shell without closing descriptors, so each shell would hold
    /// these ends open. The child's own ends are unaffected: `dup2` clears the flag.
    static func closeOnExec() -> Pipe {
        let pipe = Pipe()
        for descriptor in [pipe.fileHandleForReading.fileDescriptor, pipe.fileHandleForWriting.fileDescriptor] {
            _ = fcntl(descriptor, F_SETFD, fcntl(descriptor, F_GETFD) | FD_CLOEXEC)
        }
        return pipe
    }
}
