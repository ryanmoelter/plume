import Foundation

extension Pipe {
    /// `Process` leaves its pipes inheritable, and libghostty forks every
    /// terminal's shell without closing descriptors, so each shell would hold
    /// Plume's pipe ends open and a child would never see EOF on stdin. The
    /// child's own ends are unaffected: `dup2` onto its stdio clears the flag.
    nonisolated static func closeOnExec() -> Pipe {
        let pipe = Pipe()
        for descriptor in [pipe.fileHandleForReading.fileDescriptor, pipe.fileHandleForWriting.fileDescriptor] {
            _ = fcntl(descriptor, F_SETFD, fcntl(descriptor, F_GETFD) | FD_CLOEXEC)
        }
        return pipe
    }
}
