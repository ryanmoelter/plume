import Foundation

/// What `plume init zsh` prints: the one shell-integration entry point for
/// every subcommand.
nonisolated enum ShellIntegration {
    /// A subcommand's contribution: its line in the top-level list, and the
    /// body of its `case` arm in `_plume`, which runs with `words` and
    /// `CURRENT` already shifted so `words[1]` is the subcommand.
    struct Command {
        var name: String
        var summary: String
        var completion: String
    }

    static let commands: [Command] = [
        Command(name: "notify", summary: "Send a desktop notification for this tab", completion: """
            _arguments \\
              '--title[Notification title]:title:' \\
              '(--message)--body[Notification body]:body:' \\
              '(--body)--message[Notification body]:body:' \\
              '1:title:' '2:body:'
            """),
        Command(name: "presence", summary: "Print whether the Mac is awake, asleep or locked", completion: """
            _arguments '--json[Print JSON]'
            """),
        Command(name: "tab", summary: "Open tabs in this task", completion: """
            if (( CURRENT == 2 )); then
              local -a tab_commands=('new:Open a terminal tab in this task')
              _describe -t commands 'tab command' tab_commands
            else
              shift words
              (( CURRENT-- ))
              _arguments \\
                '--cwd[Starting directory]:directory:_directories' \\
                '--task[Task ID]:task ID:' \\
                '--select[Select the new tab]'
            fi
            """),
        Command(name: "init", summary: "Print shell integration", completion: """
            if (( CURRENT == 2 )); then
              _values 'shell' zsh
            else
              _arguments '--aliases[Also define shell functions for bundled tools]'
            fi
            """),
        Command(name: "help", summary: "Show help", completion: ":"),
    ]

    /// Shell functions `--aliases` adds, so a bundled tool's bare name works
    /// without its opt-in symlink. Empty until a tool needs one.
    static let aliasFunctions: [String] = []

    static func zsh(aliases: Bool) -> String {
        let list = commands.map { "    '\($0.name):\($0.summary)'" }.joined(separator: "\n")
        let cases = commands.map { command in
            let body = command.completion.split(separator: "\n").map { "      " + $0 }.joined(separator: "\n")
            return "    \(command.name))\n\(body)\n      ;;"
        }.joined(separator: "\n")
        var script = """
            # Plume shell integration. Load with: eval "$(plume init zsh)"

            _plume() {
              local -a plume_commands=(
            \(list)
              )
              if (( CURRENT == 2 )); then
                _describe -t commands 'plume command' plume_commands
                return
              fi
              local command=$words[2]
              shift words
              (( CURRENT-- ))
              case $command in
            \(cases)
              esac
            }

            _plume_notify() {
              words=(plume notify "${(@)words[2,-1]}")
              (( CURRENT++ ))
              _plume
            }

            if (( $+functions[compdef] )); then
              compdef _plume plume
              compdef '_plume_notify' plume-notify
            fi

            """
        if aliases {
            for function in aliasFunctions {
                script += "\n" + function + "\n"
            }
        }
        return script
    }
}
