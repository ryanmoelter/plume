# Open fixes from the second review pass

Diagnosed, not yet fixed. Delete this file once they land.

## 1. Two permission-mode controls, and a stray "Default"

`WorkspacePickerView` carries its own permission-mode picker
(`WorkspacePickerView.swift:99,116`) that reads `task.permissionMode` and shows
**"Default"** when it is nil. `ComposerControlsRow` has a second one reading
`session.permissionMode`. Both render, so the mode appears twice — the
"Default" chip next to the worktree is the task-level one.

Fix: drop the picker from `WorkspacePickerView`. The session-backed control in
the composer is the one that reflects reality.

## 2. The worktree is still its own row

`ChatComposer.body` renders `WorkspacePickerView` as the first child of the
outer `VStack` (`ChatComposer.swift:87`), above the text field.

**Requested:** move it into the controls row, left-aligned, sharing the row
with model / effort / permission mode.

I also added a *second* worktree segment to `StatuslineStripView`
(`workspaceSegment`) instead of moving this one — remove that, it is a
duplicate.

## 3. The effort dropdown never appears

`ComposerControlsRow` guards each control on a non-nil session value
(`ComposerControlsRow.swift:43,73,93`). `session.effort` is only ever assigned
in `setEffort`, and there is no `set_effort` control request to correct it from
the stream, so it stays nil forever and the control never renders. `model` has
the same shape but does get corrected from `.initialized`.

Fix: seed `effort` at launch from the same source the CLI uses, or render the
control with a placeholder rather than hiding it. Hiding a control because its
value is unknown is the wrong default — the user cannot set what is not shown.

## 4. The context window segment is missing

`contextUsedTokens` and `contextWindow` are only assigned in `endTurn`
(`HeadlessSession.swift:290-291`), so both are nil until a turn completes in
*this* process. A resumed conversation shows no context segment at all despite
the context being full.

Fix: seed from the transcript's last usage on resume, or read it from the
`.initialized` event if it carries a window.

## 5. `/compact` shows nothing while it runs

The CLI intercepts `/compact` before it reaches the model, so it never lands in
the transcript — verified: this project's transcript holds **11**
`compact_boundary` markers and **zero** `/compact` user messages. `submit(text:)`
only sends; the chat renders from the transcript, so the user's own command
vanishes and nothing appears for ~96s until compaction finishes.

Fix needs a local echo: a message Plume renders from its own state because the
transcript will never carry it, plus a working indicator. This generalizes to
any CLI-intercepted slash command, not just `/compact`.

## 6. Approving a plan does not start auto mode

Reported by the user and not yet investigated. `answerPlan(.approve)` resolves
the permission request and minimizes the overlay; whatever auto mode requires
beyond that is unknown.

## Questions the user asked that were answered unilaterally

Flagged because they were questions, not instructions:

- **"reject" vs "give feedback"** — shipped as "Give feedback".
- **Should the feedback submit button sit inside the text field?** — not done;
  Return-to-submit was added instead, which is a different thing.
- **Compacted context "at the very least behind a dropdown"** — shipped as a
  collapsed marker row, which may not be the disclosure that was meant.
- **Worktree in the composer or the statusline?** — the user said either was
  fine, then specified the composer. See item 2.
