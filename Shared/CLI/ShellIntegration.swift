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
        Command(name: "wt", summary: "Manage worktrees", completion: wtCompletion),
        Command(name: "init", summary: "Print shell integration", completion: """
            if (( CURRENT == 2 )); then
              _values 'shell' zsh
            else
              shift words
              (( CURRENT-- ))
              _arguments '--aliases[Also define bare wt, whose switch cds]'
            fi
            """),
        Command(name: "help", summary: "Show help", completion: ":"),
    ]

    /// The `wt` arm of `_plume`, with `words[1]` = `wt`.
    private static let wtCompletion = """
        if (( CURRENT == 2 )); then
          local -a wt_commands=(
            'list:show worktrees + status'
            'l:show worktrees + status'
            'checkout:check out a branch in a new worktree (-b creates)'
            'co:check out a branch in a new worktree (-b creates)'
            'cob:create a branch and check it out in a new worktree'
            'background:move the current branch and changes to a new worktree'
            'bg:move the current branch and changes to a new worktree'
            'foreground:take another worktree branch and changes into this one'
            'fg:take another worktree branch and changes into this one'
            'rename:rename the branch, -f also the folder'
            'r:rename the branch, -f also the folder'
            'commit:commit -a in another worktree'
            'cm:commit -a in another worktree'
            'open:open a worktree in a new Plume tab'
            'o:open a worktree in a new Plume tab'
            'switch:cd to a worktree or checked-out branch'
            's:cd to a worktree or checked-out branch'
            'path:print the path to a worktree'
            'current:report the current worktree and branch'
            'delete:remove a worktree, keeping its branch'
            'd:remove a worktree, keeping its branch'
            'prune:delete merged worktrees, then merged branches'
            'p:delete merged worktrees, then merged branches'
            'setup:open Settings, Projects in Plume'
            'help:show usage and the resolved settings'
          )
          _describe -t commands 'wt command' wt_commands
        else
          local -a worktrees branches
          case $words[2] in
            switch|s|path)
              worktrees=("${(@f)$(command plume wt __complete worktrees)}")
              branches=("${(@f)$(command plume wt __complete branches)}")
              _describe 'worktree' worktrees
              _describe 'branch' branches
              ;;
            checkout|co)
              branches=("${(@f)$(command plume wt __complete checkoutable)}")
              _describe 'branch' branches
              ;;
            open|o|delete|d|rename|r|commit|cm|foreground|fg)
              worktrees=("${(@f)$(command plume wt __complete worktrees)}")
              _describe 'worktree' worktrees
              ;;
          esac
        fi
        """

    /// `aliases` adds a bare `wt()`, completing as `plume wt`.
    static func zsh(aliases: Bool = false) -> String {
        let list = commands.map { "    '\($0.name):\($0.summary)'" }.joined(separator: "\n")
        let cases = commands.map { command in
            let body = command.completion.split(separator: "\n").map { "      " + $0 }.joined(separator: "\n")
            return "    \(command.name))\n\(body)\n      ;;"
        }.joined(separator: "\n")
        return """
            # Plume shell integration. Load with: eval "$(plume init zsh)", or add --aliases for wt switch

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
            \(aliases ? wtFunction : "")
            """
    }

    private static let wtFunction = """

        # A subprocess can't cd this shell, so `wt switch` becomes a cd to the
        # path `wt path` prints.
        wt() {
          if [[ $1 == switch || $1 == s ]]; then
            local target
            target="$(command plume wt path "${@:2}")" || return $?
            cd "$target"
          else
            command plume wt "$@"
          fi
        }

        _plume_wt() {
          words=(plume wt "${(@)words[2,-1]}")
          (( CURRENT++ ))
          _plume
        }

        if (( $+functions[compdef] )); then
          compdef _plume_wt wt
        fi

        """
}
