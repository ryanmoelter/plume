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

`BundledSkills` copies rather than symlinks, so an installed skill outlives the bundle it came from. Beside each `SKILL.md`, install writes `.plume-skill.json`, which records `{"hash": <SHA-256 of the bundled file>, "plumeBuild": <CFBundleVersion>}`. It stages the folder and moves it into place, so a skill and its manifest always land together.

`BundledSkills.state(of:in:)` reads one name:

| State | Meaning | What Plume does |
|---|---|---|
| `notInstalled` | Nothing at the name, not even a dangling symlink. | Installs on request. |
| `installed` | The manifest and `SKILL.md` both match this bundle. | Nothing. |
| `outdated` | The manifest matches `SKILL.md`, but not this bundle, and its recorded build is older than the running one (or missing). A newer or equal build with a different hash counts as `installed`, because every build shares `~/.claude/skills`. | The sidebar footer shows **Skills Out of Date**; clicking it updates every one. |
| `ownedByOther` | A symlink, or a file or folder without a manifest. | Nothing, unless the user picks **Replace**. |
| `modified` | `SKILL.md` no longer matches its manifest, or the folder holds a file besides `SKILL.md` and the manifest. | Nothing, unless the user picks **Replace**. |

**Replace trashes before it installs.** `install(_:replacing: true)` moves a real folder to the Trash first. A symlink is deleted as the link only, never its target. Without `replacing`, install refuses both of the last two states. Update rewrites only `SKILL.md` and the manifest. Uninstall trashes only `installed` and `outdated` copies.

`BundledSkillsStatus` holds the states for the UI. It reads them off the main actor at launch, whenever the app becomes active, and after every change. Home offers **Install** until Plume owns any skill, unless the user picks **Not Now** (`AppSettings.bundledSkillsPromptDismissed`). Install there skips any name that something else holds, and shows the first failure. Home and Settings hide the skills UI unless Claude Code is installed. **Settings ▸ Agents ▸ Plume skills** lists every skill with its state, and offers Install, Update, Replace and Remove.

## The formatting rule

`Plume/Resources/Skills/plume-formatting-rule.md` tells the agent how Plume renders its replies: Linear and GitHub pull request links become chips, file links become file chips, `mermaid` fences become diagrams, and tables and code fences have limits. Keep it short and accurate to the renderer: `ReferenceTarget.classify` decides which links chip, and `MermaidDocument` which fences draw.

Both Claude transports pass it as `--append-system-prompt-file <path>` (`AgentPromptRule`). A file path rather than `--append-system-prompt <text>`, so no multi-line argument has to survive the terminal transport's shell quoting. `claude --help` names the flag only in passing, but the CLI reads it in every mode, merges it with any `--append-system-prompt`, and refuses to start if it can't read the file. So `AgentPromptRule.formattingPath` is nil when the resource is missing, and the launch drops the flag.
