# Porting `wt` into `plume wt`

PLUME-316 ports Ryan's Python `wt` tool (`dotfiles/cli-tools/src/wt` and `src/_common/`) into the `plume` CLI as `plume wt …`. A `wt` executable name, or the `wt` function from `plume init zsh --aliases`, routes to the same code. This page maps the Python to the Swift and splits the remaining work into four groups.

Stage 1 is the skeleton and the ported tests. Every unported function is a stub that returns an empty value or does nothing; none of them traps. Each stub carries a `TODO(PLUME-316 group X)` naming the group that implements it, and the tests fail until that group lands.

## Decisions

- Every subcommand and alias ports: `list`/`l`, `checkout`/`co`, `cob`, `background`/`bg`, `foreground`/`fg`, `rename`/`r`, `commit`/`cm`, `open`/`o`, `switch`/`s`, `path`, `current`, `delete`/`d`, `prune`/`p`, `setup`, `help`, and the hidden `__complete`. The deprecated `new`/`n` shim does not port.
- In the standard layout, new worktrees go under `<repo>/.plume/worktrees`. `<repo>/.plume/.gitignore` contains `*`, so the directory ignores itself and the repository's own `.gitignore` stays untouched. The bare layout keeps its sibling directories.
- Plume tabs replace cmux and Ghostty. Inside Plume, a worktree opens with `tab.new`. `--task` (or `--workspace`, kept for muscle memory) opens it as a task instead. `--no-tab` opens nothing. Outside Plume, or when the request fails, `wt` prints `wt: <dir>` and `wt: (cd "<dir>")`. A failed tab request never falls back to a task.
- `switch` opens a tab inside Plume. Outside Plume it fails and tells the user to load `eval "$(plume init zsh)"`, whose `plume()` wrapper `cd`s through `command plume wt path`.
- Settings come from Settings ▸ Projects, not `git config`. The app stores a `ProjectsConfiguration` as JSON data under the `projectsConfiguration` key. The tool reads it from the suite named by `PLUME_BUNDLE_ID`, else `com.ryanmoelter.Plume`. A repository's value overrides the defaults field by field, an explicit empty string counts as a value, and a list replaces the default list. Settings ▸ Projects (`ProjectsSettingsPane`) writes it through `AppSettings.projectsConfiguration`, keyed by `ProjectRoot.containing`, which derives the root through the same `WorktreeContext.locate` the tool uses.
- The ignored-pending-checks list is a `TerminalUI` parameter read from settings, not a global.

## Python to Swift

| Python | Swift |
|---|---|
| `_common/gitcore.py`: `run_`, `die`, `warn`, `set_quiet`, `set_prog` | `Shared/CLI/Git/CLIProcess.swift`, `CLIConsole.swift` (`CLIFailure`, `CLIConsole`, `BufferConsole`) |
| `_common/gitcore.py`: `ConfigMixin`, `apply_display_settings` | `Shared/CLI/Git/ProjectSettings.swift` (`ProjectSettings`, `ProjectsConfiguration`, `UserDefaultsProjectSettingsSource`), `Shared/CLI/WT/WTSettings.swift` |
| `_common/gitcore.py`: `Git` | `Shared/CLI/WT/WorktreeGit.swift` (`WorktreeGit`, `ProcessWorktreeGit`, `WorktreePorcelain`) |
| `_common/ui.py`: `set_color`, `set_glyphs`, `hyperlink`, `glyph_key`, `pr_chip`, `pr_loading_chip`, `pr_net_off_chip`, `branch_pr_chip`, `redraw_prefix` | `Shared/CLI/Git/TerminalUI.swift` (`TerminalUI`, `Chip`, `GlyphKeyEntry`) |
| `_common/forge.py`: `forge_kind`, `gitlab_fullpath` | `Shared/Forge/ForgeKind.swift` (`ForgeKind.resolving`), `Shared/Forge/GitLabQuery.swift` (`fullPath`) |
| `_common/forge.py`: `build_github_query`, `pick_best`, `normalize_github`, `rollup_checks` | `Shared/Forge/GitHubQuery.swift`, `CheckRollup.swift`, `PullRequest.swift` (moved from the app, already implemented) |
| `_common/forge.py`: `build_gitlab_query`, `normalize_gitlab` | `Shared/Forge/GitLabQuery.swift` |
| `_common/forge.py`: `Gh`, `Gl`, `fetch_github_prs`, `fetch_gitlab_prs` | `Shared/Forge/ForgeBackend.swift` (`GitHubBackend`, `GitLabBackend`, `ForgeBackends`) |
| `_common/forge.py`: `start_fetch`, `resolve_pr_state` | `Shared/Forge/PRFetch.swift` |
| `wt`: `TabOpener` | `Shared/CLI/WT/TabOpener.swift` (`PlumeCaller`, `PlumeAppClient`, `PlumeTabOpener`) |
| `wt`: `WtGit`, `Ctx`, `detect_ctx`, `_prefix_resolution` | `Shared/CLI/WT/WorktreeContext.swift` (`WTContext`, `WorktreeContext.detect`) |
| `wt`: `branch_prefix`, `branch_for`, `folder_for_branch`, `resolve_branch`, `display_location`, `path_for_branch` | `Shared/CLI/WT/WTHelpers.swift` |
| `wt`: `status_cluster`, `colorize_cluster`, `_truncate`, `build_rows`, `render_list`, `build_list_json`, `print_list_live`, `start_pr_fetch` | `Shared/CLI/WT/WTList.swift` |
| `wt`: `is_merged_locally`, `_merge_reason`, `prune_candidates`, `bare_branch_candidates` | `Shared/CLI/WT/WTPrune.swift` |
| `wt`: `cmd_*`, `_setup_*`, `usage` | `Shared/CLI/WT/WTCommands.swift` |
| `wt`: `main` | `Shared/CLI/WT/WTMain.swift` (`WT.main`, `WT.run`), routed from `CLICommandLine` and `PlumeCLI/main.swift` |
| `wt`: `cmd_init` | `Shared/CLI/ShellIntegration.swift` (`plume init zsh [--aliases]`) |

The Python stack fields in `forge.py` belong to the `stack` port (PLUME-317), not this one.

## Tests

| Python | Swift |
|---|---|
| `tests/fakes.py` | `PlumeTests/CLI/WT/WTTestSupport.swift` |
| `test_forge.py` | `PlumeTests/CLI/Git/ForgeTests.swift`, chip cases in `TerminalUITests.swift` |
| `test_shared_config.py` | `PlumeTests/CLI/Git/TerminalUITests.swift`, `ProjectSettingsTests.swift`, `PlumeTests/CLI/WT/WTDerivedSettingsTests.swift` |
| `test_wt_discovery.py` | `WTDiscoveryTests.swift`, `WTGitIntegrationTests.swift` |
| `test_wt_list.py` | `WTListTests.swift`, `WTHelperTests.swift` |
| `test_wt_current.py` | `WTCurrentTests.swift` |
| `test_wt_prune.py` | `WTPruneTests.swift` |
| `test_wt_tabs.py` | `WTTabsTests.swift` |
| `test_init.py` | `WTInitTests.swift`, `CLICommandLineTests.swift` |
| `test_version.py` | `WTMainTests.swift`, `WTDispatchTests.swift` |

## Groups

Each group owns whole suites, so a group is done when its suites pass. Group A has no dependencies. B needs A. C and D need B and can run in parallel.

| Group | Implements | Suites that must pass |
|---|---|---|
| A: shared layer | `CLIProcess`, `ProjectSettings`, `TerminalUI`, `ForgeKind.resolving`, `GitLabQuery`, `ForgeBackend`, `PRFetch` | `ForgeTests`, `TerminalUITests`, `ProjectSettingsTests` |
| B: discovery and dispatch | `WorktreeGit`, `WorktreeContext`, `WTHelpers`, `WTSettings`, `WT.main`/`run`, `path`, `__complete`, `buildRows`, `statusCluster` | `WTDiscoveryTests`, `WTHelperTests`, `WTMainTests`, `WTDerivedSettingsTests`; in `WTGitIntegrationTests`, every test but `cobCreatesASelfIgnoredWorktree` |
| C: list and current | `list`, `current`, `usage`, the rest of `WTList` | `WTListTests`, `WTCurrentTests` |
| D: mutating commands, tabs, shell | `checkout`/`cob`, `open`, `background`, `foreground`, `delete`, `prune`, `rename`, `commit`, `switch`, `setup`, `TabOpener`, `WTPrune`, `ShellIntegration.zsh(aliases:)` | `WTPruneTests`, `WTTabsTests`, `WTInitTests`, `WTDispatchTests`, `CLICommandLineTests.initCompletesTheShellNameThenAliases`, `WTGitIntegrationTests.cobCreatesASelfIgnoredWorktree` |

`WTDispatchTests` checks that each alias fails the same way as its full name on bad arguments. It includes `l`/`list`, so it passes only once C has landed as well as D.
