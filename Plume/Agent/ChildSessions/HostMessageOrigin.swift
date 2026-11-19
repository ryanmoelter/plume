import Foundation

/// Who a host message speaks for, so one the user takes off a queue goes
/// back to its sender instead of into the composer.
enum HostMessageOrigin: Equatable {
    /// Notes from child sessions, waking their parent.
    case notes([ChildSessionWakePolicy.Note])
    /// Notes riding in front of a message the user wrote.
    case preamble(ChildSessionWakePolicy.Taken)
    /// The parent's brief or message to a child.
    case fromParent(text: String)
}
