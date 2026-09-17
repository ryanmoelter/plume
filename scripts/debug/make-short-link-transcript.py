import json, uuid, datetime, os
SESSION = "beefcafe-0002-4000-8000-000000000002"
CWD = "/Users/ryanmoelter/Development/Plume"
OUT = os.path.expanduser("~/.claude/projects/-Users-ryanmoelter-Development-Plume/%s.jsonl" % SESSION)
t0 = datetime.datetime(2026, 9, 16, 13, 0, 0, tzinfo=datetime.timezone.utc)
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

user("Short page with a couple of links, no scrolling needed.")
assistant("""Two links and nothing else.

The [Swift website](https://www.swift.org) is one, and
[Apple's SwiftUI docs](https://developer.apple.com/documentation/swiftui) is the other.

Some plain prose after them, with no link in it at all.""")

with open(OUT, "w") as f:
    for d in lines:
        f.write(json.dumps(d) + "\n")
print(OUT, len(lines), "lines")
