import Foundation

/// The PATH the user's terminals see. A GUI-launched app inherits only the
/// launchd PATH, so tools the user's shell profile puts on it are invisible.
nonisolated enum LoginShellPath {
    static let marker = "__PLUME_PATH__"

    /// The directories of the PATH a login, interactive zsh reports, the way
    /// Plume's terminal tabs start. zsh rather than `$SHELL`, because the
    /// line this tailors goes into `.zshrc`. Blocks on a process, so call it
    /// off the main actor. Falls back to `fallback` when the shell fails,
    /// times out or prints no PATH.
    static func directories(
        shell: String = "/bin/zsh",
        environment: [String: String] = ProcessInfo.processInfo.environment,
        timeout: TimeInterval = 5,
        fallback: [String] = fallbackDirectories()
    ) -> [String] {
        guard let output = run(shell: shell, environment: environment, timeout: timeout),
              let path = parse(output)
        else { return fallback }
        return path.split(separator: ":").map(String.init)
    }

    /// The PATH after the last marker, which skips anything a profile printed.
    static func parse(_ output: String) -> String? {
        guard let line = output.split(whereSeparator: \.isNewline).last(where: { $0.hasPrefix(marker) }) else { return nil }
        let path = line.dropFirst(marker.count)
        return path.isEmpty ? nil : String(path)
    }

    /// This process's PATH plus `~/.local/bin`, where Plume links its tool.
    static func fallbackDirectories() -> [String] {
        let inherited = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let local = URL.homeDirectory.appending(path: ".local/bin").path
        return inherited.contains(local) ? inherited : inherited + [local]
    }

    /// Reads until the shell exits rather than until EOF, because anything
    /// a profile backgrounds (`ssh-agent`, `(cmd &)`) inherits stdout and
    /// holds the pipe open. The shell leads its own process group, and the
    /// whole group is killed afterwards: an interactive zsh ignores SIGTERM,
    /// and its background jobs would otherwise outlive every read.
    private static func run(shell: String, environment: [String: String], timeout: TimeInterval) -> String? {
        var descriptors: [Int32] = [0, 0]
        guard pipe(&descriptors) == 0 else { return nil }
        let (readEnd, writeEnd) = (descriptors[0], descriptors[1])
        defer { close(readEnd) }
        _ = fcntl(readEnd, F_SETFD, FD_CLOEXEC)
        _ = fcntl(writeEnd, F_SETFD, FD_CLOEXEC)
        _ = fcntl(readEnd, F_SETFL, O_NONBLOCK)

        guard let pid = spawn(shell: shell, environment: environment, stdout: writeEnd) else { return nil }
        close(writeEnd)

        var output = Data()
        let deadline = Date().addingTimeInterval(timeout)
        var exited = false
        var reachedEOF = false
        while !exited, Date() < deadline {
            exited = hasExited(pid)
            var poller = pollfd(fd: readEnd, events: Int16(POLLIN), revents: 0)
            _ = poll(&poller, reachedEOF ? 0 : 1, exited ? 0 : 50)
            if !reachedEOF { reachedEOF = drain(readEnd, into: &output) }
        }

        kill(-pid, SIGKILL)
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1, errno == EINTR {}
        let exitedCleanly = exited && (status & 0x7f) == 0 && (status >> 8) & 0xff == 0
        return exitedCleanly ? String(decoding: output, as: UTF8.self) : nil
    }

    /// Exited but not reaped, so the pid, and with it the process group's
    /// id, can't be reused before the group is killed.
    private static func hasExited(_ pid: pid_t) -> Bool {
        var info = siginfo_t()
        return waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0 && info.si_pid == pid
    }

    /// True at EOF, false once the pipe is merely empty.
    private static func drain(_ descriptor: Int32, into output: inout Data) -> Bool {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            guard count > 0 else { return count == 0 }
            output.append(buffer, count: count)
        }
    }

    private static func spawn(shell: String, environment: [String: String], stdout: Int32) -> pid_t? {
        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        posix_spawn_file_actions_addopen(&fileActions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&fileActions, stdout, STDOUT_FILENO)
        posix_spawn_file_actions_addopen(&fileActions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(
            &attributes,
            Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)
        )
        posix_spawnattr_setpgroup(&attributes, 0)
        var allSignals = sigset_t()
        sigfillset(&allSignals)
        posix_spawnattr_setsigdefault(&attributes, &allSignals)
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)

        let arguments = [shell, "-lic", "printf '\\n\(marker)%s\\n' \"$PATH\""]
        let environmentStrings = environment.map { "\($0.key)=\($0.value)" }
        let argv = arguments.map { strdup($0) } + [nil]
        let envp = environmentStrings.map { strdup($0) } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid: pid_t = 0
        guard posix_spawn(&pid, shell, &fileActions, &attributes, argv, envp) == 0 else {
            close(stdout)
            return nil
        }
        return pid
    }
}
