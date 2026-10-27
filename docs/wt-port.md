# Porting `wt` into `plume wt`

PLUME-316 ported Ryan's Python `wt` tool (`dotfiles/cli-tools/src/wt` and `src/_common/`) into the `plume` CLI as `plume wt …`. A `wt` executable name, or the `wt` function from `plume init zsh --aliases`, routes to the same code. This page records the decisions behind the port and maps the Python to the Swift, so a change to either side can find its counterpart.

## Decisions

- Every subcommand and alias ports: `list`/`l`, `checkout`/`co`, `cob`, `background`/`bg`, `foreground`/`fg`, `rename`/`r`, `commit`/`cm`, `open`/`o`, `switch`/`s`, `path`, `current`, `delete`/`d`, `prune`/`p`, `setup`, `help`, and the hidden `__complete`. The deprecated `new`/`n` shim does not port.
- In the standard layout, new worktrees go under `<repo>/.plume/worktrees`. `<repo>/.plume/.gitignore` contains `*`, so the directory ignores itself and the repository's own `.gitignore` stays untouched. The bare layout keeps its sibling directories.
- Plume tabs replace cmux and Ghostty. Inside Plume, a worktree opens with `tab.new`. `--task` (or `--workspace`, kept for muscle memory) opens it as a task instead. `--no-tab` opens nothing. Outside Plume, or when the request fails, `wt` prints `wt: <dir>` and `wt: (cd "<dir>")`. A failed tab request never falls back to a task.
- Only the bare `wt()` from `eval "$(plume init zsh --aliases)"` can `cd`: it runs `wt switch` as a `cd` to the path `command plume wt path` prints. `plume init zsh` defines no `plume()` function, so all of `plume` stays a plain command and `plume wt switch` never changes directory. Reaching the binary's `switch` opens a tab inside Plume; outside Plume it fails and tells the user to load `--aliases` and run bare `wt switch`. Without `--aliases`, a bare `wt` runs the binary through its `wt` link and cannot `cd` either.
- Settings come from Settings ▸ Projects, not `git config`. The app stores a `ProjectsConfiguration` as JSON data under the `projectsConfiguration` key. The tool reads it from the suite named by `PLUME_BUNDLE_ID`, else `com.ryanmoelter.Plume`. A repository's value overrides the defaults field by field, an explicit empty string counts as a value, and a list replaces the default list. Settings ▸ Projects (`ProjectsSettingsPane`) writes it through `AppSettings.projectsConfiguration`, keyed by `ProjectRoot.containing`, which derives the root through the same `WorktreeContext.locate` the tool uses.
- The app reads the same settings. The New Worktree sheet suggests a branch under the prefix `wt` would use (`WorkspaceProvisioner.configuredBranchPrefix`), including the `user.email` fallback. Both the sidebar's PR chips and `wt` ignore the project's pending checks, through the one `IgnoredChecksResolver`. Neither reads git config.
- The ignored-pending-checks list is a `TerminalUI` parameter read from settings, not a global.
- Settings ▸ Integrations used to hold a Plume-wide ignored-checks list under the `ignoredPendingChecks` user default. At launch, after the git-config import, `AppSettings.migrateLegacyIgnoredPendingChecks` appends it to the defaults row's list and deletes the key. It runs after the import because the import never fills a field that is already set.
- The Nerd Font mode is one global setting, in Settings ▸ Command line, not a project setting. It is `automatic`, `on` or `off` (`NerdFontMode`), stored as its raw value under the `nerdFontMode` key in the app's domain (`AppSettings.nerdFontMode`), and the tool reads it from the same suite as `projectsConfiguration` (`ProjectSettingsSource.nerdFontMode()`). Unset means `automatic`. Automatic uses the icons inside a Plume tab (`PLUME_TAB_ID` is set) or any Ghostty terminal (`TERM_PROGRAM` is `ghostty`), whatever the configured font, and the plain glyphs elsewhere. Plume's terminals and Ghostty fall back to an embedded Symbols Nerd Font for icons the font lacks. The "merged" icon is `nf-oct-git_merge` (U+F419), which the bundled Cascadia Code NF has. Below the picker, a preview draws every glyph a `wt list` row can print (`TerminalUI.listGlyphs`) in the terminal theme's colors on its background (`ThemeChrome.terminalColors`).
- `ProjectSettings.nerdFont` is retired. It still decodes, a `Bool` from before the automatic mode as `on` or `off`, so old configurations load. While the global key is unset, the defaults row's value stands in for it: `AppSettings` copies it into the key at launch, once, and the tool falls back to it until then. A project's own value is never read.
- The first launch of an upgraded app imports the Python tools' git config into Settings ▸ Projects, once (`GitConfigSettingsImport`). Global config fills the defaults row. Each known repository (tasks' `repoPath`s and rows already in Projects, keyed through `ProjectRoot`) gets the fields where its merged config resolves differently from global. A field already set in Projects is never overwritten, and a repository that imports nothing gets no row. The `importedGitConfigProjectSettings` user default records completion. It runs off the main actor at launch rather than when Settings opens, so the New Worktree sheet and `wt` see the values without Settings ever being shown. The tool does not run the import: the app writes `projectsConfiguration` from its in-memory copy and would overwrite whatever the tool wrote, and an upgrade always relaunches the app before the tool could need the values.
- `wt` works from the bare layout's root folder and from its `.bare`, though neither is a checkout. `WorktreeContext.locate` finds the layout from a `.bare` in the working directory before it asks git for a toplevel.
- `help`, `-h`, `--help` and a bare `wt` work outside a git repository. There they print only the commands, with no resolved-settings summary. `current --json` prints every field as `null` there and succeeds, and `__complete` prints nothing and succeeds.
- A configured branch prefix is trimmed and given a trailing `/` (`WTSettings.normalizedBranchPrefix`), in the tool and the app alike. A whitespace-only prefix counts as unset.
- `prune` deletes a merged or closed PR's branch only when the PR's head (`headRefOid`) contains it: the local head equals it or is an ancestor of it. Otherwise the branch has commits the PR lacks, and `prune` skips it with a note, unless the base already contains it. A worktree whose status git cannot read, such as one whose folder was deleted by hand, is skipped with a warning, and the run carries on. So is a worktree or branch git refuses to delete, and then `prune` exits non-zero at the end, naming each one.
- `list` on a terminal prints the table at once with loading chips, then redraws it when the PR fetch lands or its 8-second budget runs out, with the Python tool's escapes: cursor up over the frame, then clear to the end of the screen (`WT.printListLive`). Unlike the Python tool, it counts wrapped lines against the terminal width, from each line's display columns (`WT.screenRows`, `TerminalUI.displayWidth`). A frame with no row to spare below it can't be rewound, because cursor-up stops at the top of the screen (`WT.redrawsInPlace`), so the resolved frame prints below the loading one. Piped output and `--json` print once.
- `list` scans up to `WT.statusWorkers` worktrees at once, since each status is a few git processes. `CLIProcess.run` waits on a `terminationHandler` rather than `waitUntilExit`, which polls a run loop and added about 70 ms to every child; with both, the first frame went from about 2.6 s to about 0.2 s on an 11-worktree checkout.
- `bg` and `fg` restore their stash by its commit SHA (`git stash apply <sha>`, then a drop of that entry), never by `stash@{0}`. The stash list is shared by every worktree, so another process may push in between.
- `bg` and `fg` run every check that can refuse before they stash. A step that fails after the stash restores it, or names its SHA and the `git stash apply` that gets it back. Both refuse a detached HEAD: `bg` because `worktree add HEAD` resolves in the repository rather than the current worktree, and `fg` because removing a detached source orphans its commits.

### Imported git-config keys

Keys are case-insensitive. The shared section is `ryanmoelter-cli-tools`. Each field takes the first key in its chain that is set. The Python tools ranked their own section above the shared one; Plume keeps one value for both tools, so `wt`'s chain comes first and `stack` fills only what neither sets. A single-valued key takes its last value, as `git config --get` does. A list comes whole from the first key with any values, as `config_chain_all` did, and is never merged across keys.

| Field | Keys, in order | Notes |
|---|---|---|
| `branchPrefix` | `wt.branchPrefix`, `ryanmoelter-cli-tools.branchPrefix`, `stack.branchPrefix` | An empty value imports as "no prefix". |
| `baseBranch` | `wt.baseBranch`, `ryanmoelter-cli-tools.baseBranch`, `stack.baseBranch` | An empty value is skipped, since Python fell back on it. |
| `forge` | `wt.forge`, `ryanmoelter-cli-tools.forge`, `stack.forge` | `github`, `gitlab` or `none`, any case. Anything else is skipped. |
| `nerdFont` | `wt.nerdFont`, `ryanmoelter-cli-tools.nerdFont`, `stack.nerdFont` | `true`/`yes`/`on`/`1` imports as `on`, any other value as `off`, as `config_get_bool` read it. Global config only: it sets the global mode when that is unset, and a repository's value is ignored. |
| `protectedWorktrees` | `wt.protected`, `ryanmoelter-cli-tools.protectedWorktrees` | Multi-value (`git config --add`). `stack` had none. |
| `ignoredPendingChecks` | `wt.ignoredPendingChecks`, `ryanmoelter-cli-tools.ignoredPendingChecks`, `stack.ignoredPendingChecks` | Multi-value. |

`stack.githubStacksEnabled` is a cache, not a setting, and is not imported.

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
