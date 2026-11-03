# Agent skills and the formatting rule

Plume teaches Claude Code about itself in two ways: skills it copies into `~/.claude/skills`, and a formatting rule it appends to the system prompt of every `claude` it launches. Codex gets neither.

## What Plume bundles

`Plume/Resources/Skills/` holds one file per skill, `<name>.skill.md`:

| Skill | Teaches |
|---|---|
| `plume-cli` | `plume notify`, `presence`, `tab new` and `init` |
| `plume-worktrees` | `plume wt` |
| `plume-stack` | `plume stack` |
| `plume-devices` | `plume devices` |

Each skill is written for any Plume user, so it names no personal setup. Check a skill's commands and flags against `docs/cli.md` and the tool's own `help` whenever the tool changes.

**The files are flat because resources are.** The synchronized group copies every resource into `Contents/Resources` with no folders, so a second `SKILL.md` would collide with the first. Install writes each file out as `~/.claude/skills/<name>/SKILL.md`. A test (`BundledSkillResourceTests`) checks that each file's frontmatter `name` matches its file name.

## Install and the manifest

`BundledSkills` copies rather than symlinks, so an installed skill outlives the bundle it came from. Beside each `SKILL.md`, install writes `.plume-skill.json`, which records `{"hash": <SHA-256 of the bundled file>, "plumeBuild": <CFBundleVersion>}`. It writes both files into a staging folder beside the skill's folder, then moves it into place, or swaps it over an outdated folder with one `replaceItemAt`. Just before the swap it reads the folder's state again and skips the skill unless it is still `outdated`. A skill and its manifest always land together, and a failed install removes its staging folder.

`BundledSkills.state(of:in:)` reads one name:

| State | Meaning | What Plume does |
|---|---|---|
| `notInstalled` | Nothing at the name, not even a dangling symlink. | Installs on request. |
| `installed` | The manifest and `SKILL.md` both match this bundle. | Nothing. |
| `outdated` | The manifest matches `SKILL.md`, but not this bundle, and its recorded build is older than the running one (or missing). A newer or equal build with a different hash counts as `installed`, because every build shares `~/.claude/skills`. | The sidebar footer shows **Skill Updates**; clicking it updates every one. |
| `ownedByOther` | A symlink, or a file or folder without a manifest. | Nothing, unless the user picks **Replace**. |
| `modified` | `SKILL.md` no longer matches its manifest, or the folder holds a file besides `SKILL.md` and the manifest. | Nothing, unless the user picks **Replace**. |

**Replace trashes before it installs.** `install(_:replacing: true)` moves a real folder to the Trash first. A symlink is deleted as the link only, never its target, and the Replace dialog says so. Without `replacing`, install refuses both of the last two states. **Skill Updates** counts more than outdated copies, and one click handles all of them. Once Plume owns any bundled skill, a `notInstalled` skill counts too, since a newer Plume added it, and the click installs it. A retired skill counts as well: a folder in `~/.claude/skills` that holds a valid Plume manifest, isn't in the bundle, and isn't `modified`. The click moves it to the Trash. A modified retired folder stays, and `ownedByOther` and `modified` bundled names never count (`BundledSkills.refreshPending`, `retiredFolders`). Update swaps the whole folder, which holds only those two files. Uninstall trashes only `installed` and `outdated` copies.

`BundledSkillsStatus` holds the states for the UI. It lists the bundled skills (once per process) and reads their states off the main actor at launch, whenever the app becomes active, and after every change. Home offers **Install** until Plume owns any skill, unless the user picks **Not Now** (`AppSettings.bundledSkillsPromptDismissed`). Install there skips any name that something else holds. A successful install from Home or Settings sets the same flag, so removing every skill later never brings the offer back. Each surface keeps its own error (Home install, sidebar refresh, Settings changes). **Not Now** also clears Home's error, so a failed install never pins the offer. The sidebar row shows "Update failed" with the error as its help text. Home and Settings hide the skills UI unless Claude Code is installed. **Settings ▸ Agents ▸ Plume skills** lists every skill with its state, and offers Install, Update, Replace and Remove. The status carries an `isSymlink` flag per skill, read off the main actor, and Replace's confirm button reads "Remove Link and Replace" for a symlink and "Move to Trash and Replace" for a folder.

## The formatting rule

`Plume/Resources/Skills/plume-formatting-rule.md` tells the agent how Plume renders its replies: Linear and GitHub pull request links become chips, file links become file chips, `mermaid` fences become diagrams, and tables and code fences have limits. Keep it short and accurate to the renderer: A path with spaces needs angle brackets, `[name](</path/with space>)`. `ReferenceTarget.classify` decides which links chip, and `MermaidDocument` which fences draw.

Both Claude transports pass it as `--append-system-prompt-file <path>` (`AgentPromptRule`). A file path rather than `--append-system-prompt <text>`, so no multi-line argument has to survive the terminal transport's shell quoting. `claude --help` names the flag only in passing, but the CLI reads it in every mode, merges it with any `--append-system-prompt`, and refuses to start if it can't read the file. So `AgentPromptRule.formattingPath` is nil when the resource is missing, and the launch drops the flag.
