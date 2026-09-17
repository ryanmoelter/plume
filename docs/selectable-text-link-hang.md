# Clicking a chat link while the composer has focus hung the app (PLUME-106)

Fixed in `MarkdownComposerTextView`, which no longer binds the composer's focus through SwiftUI's `FocusState`. This records why, so the shape is not reintroduced, and how to reproduce it without touching the pointer or the frontmost window.

## Symptom

With the composer holding keyboard focus, clicking a markdown link in the transcript spun the main thread at 100% forever. Either condition alone was harmless. The stack was AppKit's TextKit 2 mouse-tracking loop, `-[NSTextView _bellerophonTrackMouseWithMouseDownEvent:…checkForLink:…]`, entered from SwiftUI's `SelectionTextField` (the `NSTextField` behind `.textSelection(.enabled)`). lldb on the live hang showed the window's field editor with `window == nil` and `superview == nil`: the view whose tracking loop was still on the stack had been removed from the hierarchy. `[[self window] nextEventMatchingMask:…]` on nil returns instantly, never a mouse-up, so the loop re-runs its hit test forever.

## Cause

The composer bound one `@FocusState` two ways: passed into the `NSViewRepresentable` for the coordinator to write, and applied with `.focused($inputFocused)` on the same view. On the click, the text field made its field editor first responder, the composer resigned, and the coordinator wrote `false` into the binding. SwiftUI treats a programmatic `false` on a `.focused` binding as a request to give up focus and resigns whatever is first responder at that moment. That ran inside a layout pass the tracking loop itself pumped, and the first responder by then was the field editor:

```
-[NSWindow makeFirstResponder:]                              (responder = nil)
SwiftUI`FocusStore.Entry.updateFocus(_:)
SwiftUI`closure in FocusStoreLocation.set(_:transaction:)
SwiftUICore`static Update.dispatchActions()
SwiftUICore`ViewGraphRootValueUpdater.render(…)
SwiftUI`NSHostingView.layout()
AppKit`-[NSView _layoutSubtreeWithOldSize:] …
AppKit`-[NSWindow layoutIfNeeded]
AppKit`NSDisplayCycleFlush
QuartzCore`CA::Transaction::commit()
CoreFoundation`__CFRunLoopDoObservers
HIToolbox`ReceiveNextEventCommon                             (the tracking loop's event pump)
```

The next breakpoint in the same run was `-[NSTextField textDidEndEditing:]`, reached from `-[NSTextView(NSSharing) resignFirstResponder]` under that same `makeFirstResponder:`, followed by the field editor's `removeFromSuperview`. Plain prose never hung because its selection path does not stay in the tracking loop across a run-loop turn; a link run defers to mouse-up (`checkForLink:YES`), which is the window the focus write landed in.

## Fix

`MarkdownComposerTextView.isFocused` is a plain `Binding<Bool>` and the callers hold `@State`, so SwiftUI's focus system never owns the composer. `updateNSView` still claims first responder when the binding turns true, which is how a tab takes focus on becoming visible. `ComposerNSTextView` mirrors gains and losses from `becomeFirstResponder` / `resignFirstResponder` rather than `textDidEndEditing`, which `NSTextView` only posts after the text changed. Without that, a focus loss with nothing typed left the binding stale at `true` and the next update stole focus back.

## Reproducing without the pointer

`LinkClickHarness` (DEBUG) posts the click as in-process `NSEvent`s and makes the window key without activating the app, so a repro never takes over the frontmost window or moves the mouse. Launch in the background with its own `HOME` so the store is throwaway:

```
python3 scripts/debug/make-short-link-transcript.py /tmp/link.jsonl
open -g -n --env HOME=/tmp/plume-home --env PLUME_SEED_TASKS=1 \
  --env PLUME_SEED_TRANSCRIPT_PATH=/tmp/link.jsonl \
  --env PLUME_SYNTHETIC_LINK_CLICK=8 \
  <DerivedData>/Build/Products/Debug/Plume.app
sleep 12; ps -o stat=,%cpu= -p <pid>          # R at 100% is the hang; S is healthy
/usr/bin/log show --predicate 'category == "link-click"' --last 1m --info
```

`PLUME_SYNTHETIC_LINK_CLICK=<seconds>` focuses the composer and clicks the first link after that delay; add `PLUME_SYNTHETIC_LINK_CLICK_UNFOCUSED=1` for the control case. The log reports the first responder before the click and again a second later; the second line never appears when the app is hung. The mouse-up is posted 150 ms after the mouse-down on purpose: with both queued at once the tracking loop exits before it pumps the run loop, and the bug never fires.

To watch for a regression rather than a hang, attach before the click fires and break on the resign:

```
lldb -p <pid> -o 'br set -n "-[NSWindow makeFirstResponder:]" -c "$x2 == 0"' -o 'br command add 1 -o "bt 60" -o continue' -o continue
```

`CGEventPostToPid` is not an alternative. It drops events unless the target is frontmost, so every script built on it had to activate Plume first, which is what kept interrupting whoever was using the machine.
