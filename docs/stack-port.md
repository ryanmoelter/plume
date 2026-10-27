# Porting `stack` into `plume stack`

PLUME-317 ported Ryan's Python `stack` tool (`dotfiles/cli-tools/src/stack`, version 0.1.2, and `src/_common/`) into the `plume` CLI as `plume stack …`. A `stack` executable name, or the `stack` function from `plume init zsh --aliases` (or `--alias stack`), routes to the same code. This page records the decisions behind the port and maps the Python to the Swift, so a change to either side can find its counterpart. `docs/wt-port.md` covers the shared layers: settings, the forge backends, `TerminalUI`, and the imported git config.

## Decisions

- Every subcommand and alias ports, with the same flags, output and `--json` shape: `list`/`l`/`ls`, `la`, `create`/`c`, `split`, `track`, `untrack`, `checkout`/`co`, `prev`, `next`, `first`, `last`, `restack`, `submit`, `sync`, `setup`, `help`, and the hidden `__complete`. `stack init` fails and points at `plume init zsh`, as `wt init` does.
- The state file stays byte-compatible, so the Python tool and `plume stack` can share a repository. It is `<git-common-dir>/stack/branches.json`, shaped `{"version": 2, "branches": {name: {"parent", "base"}}}`. `StackJSON` renders it exactly as Python's `json.dump(indent=2, sort_keys=True)` does: keys sorted by code point, non-ASCII escaped as `\uXXXX` with surrogate pairs, and a trailing newline. The write goes through `mkstemp` and `rename`, so the file keeps mode 0600. Saving an empty state deletes the file. Legacy per-stack `*.json` files merge in sorted order, with the first entry for a branch winning, and are deleted on the next save.
- Two state rules are stricter than Python's. A file that fails to parse, or whose `branches` is missing or holds an entry without a string `parent` and `base`, counts as unreadable. Python skipped such a file and then overwrote it. The Swift tool moves it aside as `<name>.unreadable-<yyyyMMdd-HHmmss>` before it writes, and warns. A file with a version above 2 makes every save fail, so an older tool never downgrades a newer tool's state.
- Settings come from Settings ▸ Projects through `ProjectSettings`, as for `wt`: `baseBranch`, `branchPrefix`, `forge` and `ignoredPendingChecks`, plus the global Nerd Font mode. The tool reads no git config. The trunk is the configured base branch, else `origin/HEAD`, else `main`. The branch prefix is normalized as `wt` normalizes it, and has no `user.email` fallback.
- `stack setup` sends `settings.open` for the `projects` section. When the app refuses or is not running, it prints where the settings live. The interactive setup prompts do not port.
- Python cached whether a repository has GitHub native stacks in `git config stack.githubStacksEnabled`. The Swift tool caches it in `<git-common-dir>/stack/github-stacks-enabled`, which holds `true` or `false`. Delete the file to probe again.
- gh and glab stay soft dependencies. `list` works without them. `submit` and `sync` need a forge, and without one fail with "no GitHub or GitLab remote detected — set the forge for this repository in Plume's Settings ▸ Projects". GitLab stays supported. GitHub's native stack fields (`stack`, `stackEntry`) ride the PR query only when `stack` asks for them (`GitHubQuery.build(includeStacks:)`), so `wt` and the app's sidebar query is unchanged.
- `restack` replays commits in a dry run with `git commit-tree --no-gpg-sign`. The replayed commits are thrown away, and a signing prompt there would stall the command.
- A bare `stack`, `help`, `-h` and `--help` print the usage and succeed, outside a repository too. Outside a repository they omit the resolved settings. `__complete` prints nothing and succeeds there.
- The plain-glyph marker for a GitHub native stack member is `≡`. The Nerd Font glyph is U+F51E.

### Safety

- A push is always `--force-with-lease`, so it never drops commits the remote has that this clone has not seen.
- `sync` deletes a merged PR's branch only when the local head equals the PR's `headRefOid`. A branch with extra local commits is left alone, with its whole stack, and `sync` exits 1.
- A restack that stops on a conflict exits 3 and leaves git's rebase in place. The state is saved after each branch, so a rerun resumes where it stopped.
- `restack` refuses a detached HEAD, a rebase in progress and a dirty working tree. A branch checked out in another worktree is rebased there, and only when that worktree is clean.
- Adopting `origin/<branch>` replaces local commits only when the reflog of `refs/remotes/origin/<branch>` shows the local head was once pushed there.
- `stack` never stashes.

## Python to Swift

| Python | Swift |
|---|---|
| `stack_dir`, `state_path`, `load_state`, `save_state`, `state_lock`, `load_and_flush_locked`, `load_and_flush` | `Shared/CLI/Stack/StackState.swift`, `StackJSON.swift`, and `StackContext.swift` (`loadState`, `loadAndFlushLocked`, `loadAndFlush`, `saveState`) |
| `root_of`, `stack_of`, `children_of`, `roots_of`, `topo_order`, `depth_map`, `subtree`, `path_to`, `parent_is_trunk`, `github_stack_drift`, `plan_stack_update` | `Shared/CLI/Stack/StackGraph.swift` (`StackGraph`) |
| `parent_tip`, `needs_restack`, `behind_trunk`, `cascaded_needs_restack`, `commits_over_parent`, `trunk_distance`, `replay_floor` | `StackGraph.swift` (`StackContext` extension) |
| `_common/gitcore.py`: `Git`, as `stack` uses it | `Shared/CLI/Stack/StackGit.swift` (`StackGit`, `ProcessStackGit`) |
| `select_forge`, `require_forge`, `forge_icon_for`, `Ctx` setup in `main` | `Shared/CLI/Stack/StackContext.swift` (`StackContext.detect`, `requireForge`) |
| `_common/forge.py`: `Gh` and `Gl` (`require`, `pr_edit`, `pr_create`, the stack API) | `Shared/CLI/Stack/StackForge.swift` (`GitHubStackForge`, `GitLabStackForge`, `GitHubStackAPI`) |
| `_github_stack_dict`, the stack fields of `_GITHUB_PR_NODE` | `Shared/Forge/GitHubQuery.swift` (`includeStacks`, `stackMembership`) |
| `_graph_prefix`, `_note`, `render_stacks`, `collect_prs`, `print_stacks_live`, `cmd_list` | `Shared/CLI/Stack/StackList.swift` |
| `cmd_create`, `cmd_split`, `parse_split_args`, `interactive_split`, `track_with_parent`, `track_chain`, `cmd_track`, `cmd_untrack`, `cmd_checkout`, `nav_context`, `cmd_nav` | `Shared/CLI/Stack/StackShape.swift` |
| `require_current_tracked`, `rebase_in_progress`, `restack_preflight`, `origin_tip`, `remote_restack`, `former_origin_tips`, `rebase_branch`, `restack_stack`, `interactive_restack`, `warn_descendants_need_restack`, `cmd_restack` | `Shared/CLI/Stack/StackRestack.swift` |
| `push_branch`, `retarget_pr`, `sync_github_stack`, `cmd_submit`, `cmd_sync` | `Shared/CLI/Stack/StackSubmit.swift` |
| `cmd_setup`, `cmd_complete`, `usage`, `main` | `Shared/CLI/Stack/StackMain.swift` (`Stack.main`, `Stack.run`), routed from `CLICommandLine` and `PlumeCLI/main.swift` |
| `cmd_init`, `STACK_ZSH_INIT` | `Shared/CLI/ShellIntegration.swift` (`plume init zsh [--aliases] [--alias NAME]`) |

## Tests

| Python | Swift |
|---|---|
| `tests/load_stack.py`, `tests/fakes.py` | `PlumeTests/CLI/Stack/StackTestSupport.swift` |
| `test_stack_state.py` | `StackStateTests.swift`, `StackJSONTests.swift` |
| `test_stack_list.py` | `StackListTests.swift` |
| `test_stack_restack.py` | `StackRestackTests.swift` |
| `test_stack_sync.py` | `StackSyncTests.swift` |
| none (command dispatch, shape and navigation commands, shell integration) | `StackMainTests.swift`, `CLICommandLineTests.swift`, `CommandLineHelperTests.swift` |
