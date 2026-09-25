# Changelog

Release notes for Plume, newest first. Each heading is `## <version> (<build>)`, where the build is `CURRENT_PROJECT_VERSION`. `scripts/package-release.sh` publishes the top section as the GitHub release notes, and the top ten in the Sparkle appcast.

## 0.12.0 (27)

- Add Opus 5.5 support, and support future models
  - Picking e.g. "Opus" has always given you the latest version, and now Plume will properly show its version once the chat starts
  - Surprisingly, there's no easy way for us to get an up-to-date list of supported models from `claude` until we start a conversation
- Create and delete worktrees for tasks, no longer in beta
- Fix drag + drop for tabs and tasks
  - Drag a tab onto another task to move it there, or drag it along the tab strip to reorder it
  - Move a tab out into a new task of its own
  - Reorder tasks and groups in the sidebar by dragging
- Rebind the next/previous tab and task shortcuts in Settings
- Prompt for Full Disk Access on first launch, and show its status in Settings with a link to change it
- Fix the sidebar not being glassy
  - Still respects your theme through translucency, and automatically setting the light/dark window theme to match your ghostty theme.
- Polish chat experience
  - Streamed text fades in by word instead of typing out by character
  - Fix pasted text showing HTML tags
  - Show messages from other agents as a bubble with the sender's name
- Fix image drag + drop
- Fix send button being disabled when you return to a tab that already has text, and put the caret at the end of existing text
- Statusline & quota bars
  - Make the quota bars longer in the statusline (context stays the same size)
  - Tweak the pacing dot's presentation to improve clarity
  - Fix the sidebar quota display not using your theme's colors
- Fix folders under an already-trusted repository not counting as trusted, and show an error when an agent refuses to start
- Fix agents outliving Plume when it quits, and a restarted tab resuming a session another process was still writing
- Don't notify when an automatic resume fails on startup
- Install with Homebrew! `brew install ryanmoelter/tap/plume`

## 0.11.0 (26)

- Send images in chat
  - Drag + drop, or paste with ⌘V
  - Render attached images in the composer while writing, and in the chat afterward
- Run shell commands from the composer with a leading `!`
  - Pass the command and its output to the agent
  - Running commands show above the composer with the option to kill them
- Share current quota status across chats and add some details
  - Also shows in the sidebar
  - Add a pacing dot on each bar showing what percentage of the quota's time limit has elapsed, so you know if you'll run out of tokens at your current pace
  - Show the actual date and time of the reset in the tooltip on hover
  - Update the remaining quota times without new messages
  - The quota display dims after a while to show that it might not be accurate anymore (e.g. if you use Claude from another device)
- Generate task/tab titles from the agent for agent sessions, instead of using the first message
- Add Manual permission mode, and hide Bypass Permissions behind a setting (I recommend you use Auto mode instead)
- Fix branch and PR states not loading until you open the task
- Fix background work (e.g. a monitor) not being named in the Keep Awake reasons
- Fix a monitor keeping the app awake until its timer expired, rather than when it was done running

## 0.10.0 (25)

- Import your workspaces and tabs from cmux
  - **File → Import from cmux…** and pick what gets imported
  - Agent conversations come with their history and can pick up where they left off
  - Re-run it again later and optionally replace already-imported tasks/workspaces
- Code in chat now uses your terminal font
  - Reads `font-family`, `font-weight` and `font-style` from your ghostty config
  - Bundles Cascadia Code NF SemiLight as the default (my personal favorite monospace font)
  - A size multiplier in Settings lets you match x-heights against the prose font
- Choose whether Remote Control alone keeps your Mac awake
- Fix keyboard shortcuts being swallowed while a terminal is focused
- Fix some minor layout issues
  - Properly center the chat in the window
  - Shrink the minimap when at small window widths
- Fix tabs forgetting which directory they were working in on restore
- A plan waiting for approval always shows in a bar along the top of the composer, and otherwise lives less prominently in the composer
- Fix permission prompt alignment
- Archived tasks show relative dates
- Remove Archive option on tasks that never started
- Fix renaming a task/group in the sidebar not focusing the field sometimes
- Change the working status word every ~30s while an agent works

## 0.9.0 (24)

- Keep your Mac awake with the lid closed
  - Connect to your phone hotspot, throw your Mac in your bag, and know that Plume will put it to sleep if it gets too hot
  - Add a battery cutoff to Keep Awake ("Allow sleep below X%" when on battery)
  - Add a temperature cutoff to Keep Awake
  - Install the sleep helper from the Keep Awake popover and approve it once in Login Items
  - The sidebar Keep Awake row turns red while the lid override is active
  - The helper releases the override if Plume quits or crashes, sweeps it at every boot, and puts a shut Mac to sleep as soon as the override ends
- Keep Awake now covers background work, even if the turn finishes
  - Monitor, background Bash, and Workflow tasks
- Fix a headless agent showing as idle for a whole turn started by a task notification
- Reworded the Keep Awake popover and its Settings section

## 0.8.3 (23)

- Improve the experience starting an agent conversation
  - Add clear dropdowns for project and worktree
  - Project dropdown now skips worktree folders in favor of the project's root
- Fix clicking a link in the chat freezing Plume
- Fix archiving a task leaving its agents running
- Fix a failing chat waiting forever to start; show an error instead
- Updated the guidance around when closing the lid sleeps the Mac (more stay awake changes coming soon!)
- Made tasks that are resumed or not started dimmer than the rest, to highlight tasks that are in progress and may need your attention

## 0.8.1 (21)

- Fix lag while scrolling when any agent is working.

## 0.8.0 (20)

- Replace the chat list with a custom layout, on by default.
  - Scrolling long chats and large blocks no longer hangs!
  - Code blocks draw full-height.
  - A sent prompt moves to the top of the chat, with room below for the reply.
  - Subagent rows fold away behind the composer.
  - Jump to bottom animates.
  - To switch back, turn off "Use the new chat layout" in Settings.
- Small fixes:
  - Put the timestamp and copy button under the reply's text instead of after its tool calls, and show them once the turn finishes.
  - Show a battery icon in the keep-awake row when being on battery is keeping the Mac from staying awake.
  - Stop showing Claude Code's instructions after the answer on answered questions.

## 0.7.0 (19)

- Keep the computer awake, automagically
  - Auto mode will keep the mac awake while agents are working or remote control is on.
  - Auto mode will **not** keep the mac awake if you're on battery (unless you set "keep awake on battery")
  - Close the lid to always put the computer to sleep. This keeps the computer off when it's e.g. in your backpack.
  - Show what is holding the computer awake in the sidebar.
  - You can also set Plume to always keep the mac awake, or never do so.
- Add syntax highlighting for code blocks.
- Add a timestamp and "copy in markdown" button to each message, and a copy button to tables.
- Nested and multi-level markdown lists render correctly and copy back with their depth intact.
- Tweak spacing between messages/tool calls.
- Make the status indicator more accurate.
- Better report subagent "done" statuses, even for interrupted/orphaned subagents.
  - If a subagent still gets stuck, you can mark it as done manually in the right click menu.
- Experimental: Add a new `plume-notify` helper inside the app bundle. Install it to `~/.local/bin` from **Settings → Command Line**.
- Polish the archive view: sort by most recent and polish UI.

## 0.6.1 (18)

- Update groups in the sidebar.
  - Add a expand/collapse toggle.
  - Add a "create task" button.
  - Drag + drop to reorder groups.
- Add a status icon in the sidebar for each subagent on a task.
- Add a default color palette, which is still overridden by any theme in your ghostty config.
- Show why a mermaid diagram fell back to a code block, instead of only logging it.
- Better detect working vs. dead subagents.
- Update selected tab/task visuals.

## 0.6.0 (17)

- Add a real app icon
- Make the chat/subagent statuses more accurate, including adding a working timer
- Update status icons and make them consistent across all surfaces in the app
- Show "Sautéing" and other fun verbs for the working indicator
- Better detect "done" subagents, especially on app start
- Show remote control state on the agent row
- Update scrolling to be less likely to hang (there's still outstanding work to do here unfortunately)

No proper release DMG for this because the next release happened too quickly after it.

## 0.5.1 (16)

First signed release!
