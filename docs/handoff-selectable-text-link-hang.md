# PLUME-106: clicking a chat link hangs the app

The app spins at 100% CPU on the main thread, permanently, when a link in the
chat is clicked while the composer has keyboard focus. It is not a link-opening
bug, and every hypothesis that blamed Plume's own code has been falsified by
experiment.

Branch: `ryanm/plume-106-selectable-text`, forked from `ryanm/plume-106-fieldeditor`.
It carries `FieldEditorProbe` (DEBUG, opt-in) and nothing else.

## Reproducing it

The hang needs **both** conditions. Either alone is harmless.

1. Open a conversation containing a markdown link. Seed one with
   `python3 scripts/debug/make-link-repro-transcript.py` if none is at hand, or write a `.jsonl` into
   `~/.claude/projects/-Users-ryanmoelter-Development-Plume/` by hand.
2. Click into the composer so it holds focus. Typing is not required, and
   typing first does not prevent the hang.
3. Click a link in the transcript.

The app freezes. `ps` shows state `R` at 100% CPU.

**Not a repro:** clicking a link with the composer unfocused (the link opens
normally), or clicking ordinary non-link prose in any focus state. Clicking
empty sidebar space to drop focus first also avoids it.

## What is established

### The hung stack, identical every time

```
-[NSWindow _handleMouseDownEvent:isDelayedEvent:]
 -[NSTextField mouseDown:]
  -[NSCell editWithFrame:inView:editor:delegate:event:]
   SelectionTextField.Cell._selectOrEdit(...)            (SwiftUI)
    -[NSTextFieldCell _selectOrEdit:...]
     -[NSCell _selectOrEdit:...]
      _NSEditTextCellWithOptions
       -[NSTextView mouseDown:]
        -[NSTextView _bellerophonTrackMouseWithMouseDownEvent:...checkForLink:...]   <- spins
         -[NSTextSelectionNavigation textSelectionsInteractingAtPoint:...]
          -[NSTextSelectionNavigation _lineFragmentInfoForPoint:...]
           -[NSTextLayoutManager enumerateSubstringsFromLocation:options:usingBlock:]
            -[NSTextLayoutManager enumerateTextLayoutFragmentsFromLocation:...]
             -[NSTextContentStorage synchronizeTextLayoutManagers:]
```

No Plume frames appear anywhere in it. `_bellerophonTrackMouse…` is AppKit's
modal mouse-tracking loop for the TextKit 2 path; it pumps
`nextEventMatchingMask:untilDate:distantFuture` and normally exits on mouse-up.

### The mechanism, confirmed by lldb on three separate live hangs

```
(lldb) expr -l objc -O -- (id)[[NSApp keyWindow] firstResponder]
SwiftUI.AppKitWindow
(lldb) expr -l objc -O -- (id)[(id)[[NSApp keyWindow] fieldEditor:NO forObject:nil] window]
nil
(lldb) expr -l objc -O -- (id)[(id)[[NSApp keyWindow] fieldEditor:NO forObject:nil] superview]
nil
```

The field editor whose tracking loop is running has been **removed from the view
hierarchy while the loop is still on the stack**. Its `window` is nil, so
`[[self window] nextEventMatchingMask:…]` messages nil and returns instantly,
forever. The event type of nil is never `leftMouseUp`, so the loop never exits
and re-runs its per-iteration hit test. That is the 100% CPU.

The spin is the symptom. **The open question is who removes the field editor.**

### Why links differ from plain prose

`-[NSTextView mouseDown:]` enters tracking with `checkForLink:YES` when the
mouse-down lands on a run carrying `.link`. That defers the selection change to
mouse-up rather than applying it synchronously on mouse-down, which is what
plain prose does. The deferral leaves a window in which something else can tear
the view down mid-loop. This is inference from AppKit behavior, not disassembly.

## Hypotheses already falsified — do not re-propose

Each was tested and disproved. The evidence is listed so nobody repeats them.

| # | Hypothesis | How it died |
|---|---|---|
| 1 | Link opening (`NSWorkspace`/`openURL`) blocks | No URL frames in the stack; the click never reaches link opening |
| 2 | `.textSelection(.enabled)` alone causes it | Plain prose carries the identical modifier and never hangs |
| 3 | `ComposerNSTextView` is handed out as the window's shared field editor | Probe logged `editorIsComposer=false`, `sharesStorage=false` on the hanging click |
| 4 | A stale field editor still bound to a previous text field | Added `window.endEditing(for: nil)` before `makeFirstResponder`; probe then showed `fieldEditor=none` going in, and it still hung |
| 5 | Stale `focusBinding`, because `textDidEndEditing` only fires if the user typed | Typing a character first, then clicking a link, still hangs |
| 6 | `MarkdownComposerTextView.swift:89` re-asserting first responder detaches it | Disabled that call entirely; still hangs, field editor still detached |
| 7 | The custom list engine's host recycling (`ChatListController.free`, `remeasure`) | Ran with `PLUME_CHAT_LIST_ENGINE=lazy`, which has no pooling at all; still hangs, field editor still detached |

Test 7 is the decisive one. The LazyVStack engine has no `free()`, no
`remeasure`, no pool — and the editor is still detached. Neither container is
responsible.

Note when using the lazy engine: it has its own unrelated hang on long
transcripts (`docs/chat-list-hang.md`). Use a short transcript, two or three
messages, so scrolling is never needed.

## Where that leaves it

Plume's own code has been eliminated as the remover. What remains is SwiftUI's
`SelectionTextField` — the internal `NSTextField` subclass backing
`.textSelection(.enabled)` — rebuilding or discarding its view mid-click when
another `NSTextView` in the window holds focus. `SelectionTextField.Cell._selectOrEdit`
sits in every hung stack.

Two candidate directions, neither tried:

1. **Stop entering the state.** Drop `.textSelection(.enabled)` from the
   link-bearing prose path, or apply it only to blocks with no links. Cheap, and
   costs selection on those blocks.
2. **Intercept the click first.** Handle link clicks before AppKit's text
   machinery sees them, so the tracking loop never starts. More work, keeps
   selection.

A third option is to confirm it is an OS bug and file feedback with Apple, but
the app still needs a workaround either way.

`.textSelection(.enabled)` appears at `MarkdownBlockView.swift:20` (all blocks),
`:288` (lists) and `:338` (code). Links are parsed by
`AttributedString(markdown:)` in `MarkdownCache.swift:47`, and clicks are routed
by `ChatLinkOpener.swift:108` via `chatLinkHandling(directory:)`, applied at
`ChatTabView.swift:174`.

## The probe

`Plume/Support/FieldEditorProbe.swift`, DEBUG only, installed from
`AppDelegate.applicationDidFinishLaunching`. It logs the first responder, the
field editor and their content storage at every mouse-down. Reads state only and
passes the event through untouched.

```
PLUME_FIELD_EDITOR_PROBE=1 <DerivedData>/Plume.app/Contents/MacOS/Plume &
/usr/bin/log show --predicate 'subsystem == "com.ryanmoelter.Plume" AND category == "field-editor"' --last 5m --info
```

One known limitation: the hanging click produces **no probe line**. A local
event monitor sees events on the normal dispatch path, so the click that hangs
is taking a different route — consistent with
`_handleMouseDownEvent:isDelayedEvent:` on the stack, where AppKit defers a
mouse-down while the current first responder finishes an input session. That
deferral is a composer-focused-only condition, which may be why focus is
required. **This is the most promising untested lead.**

## Sampling a live hang

Do not quit the hung app before sampling; a live process is the evidence.

```
/usr/bin/sample <pid> 5 -file /tmp/hang.txt
lldb -p <pid>     # then the three expressions above
```

## Release context

0.8.2 is otherwise ready and is **shipping without a fix for this**. The branch
`ryanm/release-0.8.2` holds PLUME-93, 103, 104, 105 and 107, plus the bare-path
half of 106. When this work lands, message the coordinator session so the
release can be cut.
