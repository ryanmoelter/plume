import json, uuid, datetime, os

SESSION = "beefcafe-0001-4000-8000-000000000001"
CWD = "/Users/ryanmoelter/Development/Plume"
OUT = os.path.expanduser("~/.claude/projects/-Users-ryanmoelter-Development-Plume/%s.jsonl" % SESSION)

t0 = datetime.datetime(2026, 9, 16, 12, 0, 0, tzinfo=datetime.timezone.utc)
lines, prev, n = [], None, [0]

def stamp():
    n[0] += 1
    return (t0 + datetime.timedelta(seconds=n[0])).isoformat().replace("+00:00", "Z")

def base(u):
    return {"parentUuid": prev, "isSidechain": False, "uuid": u, "timestamp": stamp(),
            "sessionId": SESSION, "session_id": SESSION, "cwd": CWD, "userType": "external",
            "entrypoint": "cli", "version": "2.1.252", "gitBranch": "ryanm/plume-106-repro"}

def user(text):
    global prev
    u = str(uuid.uuid4()); d = base(u)
    d.update({"type": "user", "message": {"role": "user", "content": text}})
    lines.append(d); prev = u

def assistant(text):
    global prev
    u = str(uuid.uuid4()); d = base(u)
    d.update({"type": "assistant", "message": {"model": "claude-opus-5", "id": "msg_" + u[:24],
              "type": "message", "role": "assistant", "content": [{"type": "text", "text": text}],
              "stop_reason": "end_turn",
              "usage": {"input_tokens": 10, "output_tokens": 50, "cache_read_input_tokens": 0,
                        "cache_creation_input_tokens": 0}}})
    lines.append(d); prev = u

user("Give me a page with links in every shape, so I can click them.")

assistant("""Here they are. Each section is a different shape the renderer handles.

## Inline markdown links

The [Swift website](https://www.swift.org) is the canonical reference, and
[Apple's SwiftUI docs](https://developer.apple.com/documentation/swiftui) cover
the framework. A [link with a long descriptive label that wraps across more than
one line because the label itself is lengthy](https://developer.apple.com/documentation/swiftui/view)
tests wrapping.

Two in one sentence: [first](https://example.com/one) and [second](https://example.com/two).""")

assistant("""## Bare URLs

Not wrapped in markdown syntax at all:

https://www.swift.org/documentation/

https://github.com/apple/swift-evolution/blob/main/proposals/0296-async-await.md

Mid-sentence, the URL https://example.com/inline sits inside prose with text
after it.""")

assistant("""## Links in a table

| What | Where | Note |
|---|---|---|
| Swift | [swift.org](https://www.swift.org) | the language |
| SwiftUI | [developer.apple.com](https://developer.apple.com/documentation/swiftui) | the framework |
| Ghostty | [ghostty.org](https://ghostty.org) | the terminal |
| Bare | https://example.com/table | unwrapped in a cell |""")

assistant("""## Links in a code block

Inside a fence, these should render as text and not as links:

```swift
// See https://developer.apple.com/documentation/swiftui/view
let url = URL(string: "https://www.swift.org")!
NSWorkspace.shared.open(url)
```

And inline `https://example.com/code` in a code span.

## Links in a list

- [One](https://example.com/list-one)
- [Two](https://example.com/list-two) with trailing prose
- A nested item:
  - [Three](https://example.com/list-three)
- Bare: https://example.com/list-bare

## A reference-style link

Text pointing at [the spec][spec] and again at [the spec][spec].

[spec]: https://github.com/apple/swift-evolution""")

user("Now a long one, so there's something to scroll.")

for i in range(1, 13):
    assistant("""### Section %d

Prose before the link, long enough that the paragraph wraps at reading measure
and the link is not the first thing on its line. See [reference %d](https://example.com/section-%d)
for the details, or the bare form https://example.com/bare-%d which follows it.

- list item with [a link](https://example.com/item-%d)
- plain item with no link at all
""" % (i, i, i, i, i))

with open(OUT, "w") as f:
    for d in lines:
        f.write(json.dumps(d) + "\n")
print(OUT)
print("%d lines" % len(lines))
