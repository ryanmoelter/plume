#!/usr/bin/env python3
"""Drive a running debug Plume over its control socket.

    plume-control.py [--socket PATH | --pid N | --latest | --home DIR]
                     [--wait SECS] [--assert-frontmost] [--raw]
                     <command> [key=value ...] [--json '{...}']

Commands: list, describe, invoke, setValue, readText, clickSpan, click,
hover, clear, screenshot, hierarchy. Values parse as JSON when they can, so
`target='{"id":"composer-field"}'` and `x=10` work; anything else is a
string. Prints the response; exit 1 when the app reports an error.

`hierarchy` is the cheap way to see the window — reach for `screenshot`
only when layout is the question. Every click and hover moves an overlay
cursor in the window; `clear` removes it and un-hovers everything.
docs/control-server.md is the reference.
"""

import argparse
import glob
import json
import os
import socket
import subprocess
import sys
import time

DEBUG_DIR = "Library/Application Support/Plume.debug/control"


def discover(args):
    if args.socket:
        return args.socket
    if os.environ.get("PLUME_CONTROL_SOCKET") and not (args.pid or args.latest or args.home):
        return os.environ["PLUME_CONTROL_SOCKET"]
    home = args.home or os.path.expanduser("~")
    candidates = []
    for path in glob.glob(os.path.join(home, DEBUG_DIR, "*.sock")):
        try:
            pid = int(os.path.basename(path)[: -len(".sock")])
        except ValueError:
            continue
        if not alive(pid):
            continue
        if args.pid and pid != args.pid:
            continue
        candidates.append((os.path.getmtime(path), pid, path))
    if not candidates:
        return None
    if len(candidates) > 1 and not args.latest and not args.pid:
        pids = ", ".join(str(pid) for _, pid, _ in sorted(candidates))
        sys.exit(f"several debug instances are running (pids {pids}); pass --pid or --latest")
    return max(candidates)[2]


def alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def wait_for(path, seconds):
    """A socket file can outlive its instance (a kill skips the unlink), so
    the wait is for a socket that accepts, not one that exists."""
    deadline = time.monotonic() + seconds
    while True:
        if path and os.path.exists(path):
            try:
                with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as probe:
                    probe.settimeout(1)
                    probe.connect(path)
                return
            except OSError:
                pass
        if time.monotonic() >= deadline:
            sys.exit(f"no control socket accepting at {path or '(undiscovered)'} after {seconds}s")
        time.sleep(0.2)


def frontmost():
    try:
        out = subprocess.run(["lsappinfo", "front"], capture_output=True, text=True, timeout=5).stdout.strip()
    except (OSError, subprocess.TimeoutExpired):
        return None
    return out or None


def parse_value(raw):
    try:
        return json.loads(raw)
    except ValueError:
        return raw


def build_params(pairs, extra_json):
    params = {}
    for pair in pairs:
        if "=" not in pair:
            sys.exit(f"expected key=value, got {pair!r}")
        key, raw = pair.split("=", 1)
        params[key] = parse_value(raw)
    if extra_json:
        params.update(json.loads(extra_json))
    return params


def send(path, request):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
        sock.settimeout(30)
        try:
            sock.connect(path)
        except OSError as error:
            sys.exit(f"cannot connect to {path}: {error.strerror or error}; is that Plume still running?")
        sock.sendall((json.dumps(request) + "\n").encode())
        buffer = b""
        while b"\n" not in buffer:
            chunk = sock.recv(65536)
            if not chunk:
                sys.exit("connection closed before a response arrived")
            buffer += chunk
    return json.loads(buffer.split(b"\n", 1)[0])


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--socket")
    parser.add_argument("--pid", type=int)
    parser.add_argument("--latest", action="store_true")
    parser.add_argument("--home", help="HOME of a scratch instance, to find its socket")
    parser.add_argument("--wait", type=float, default=0, help="seconds to wait for the socket to appear")
    parser.add_argument("--assert-frontmost", action="store_true", help="fail if the frontmost app changes")
    parser.add_argument("--raw", action="store_true", help="print the whole response as JSON, even for hierarchy")
    parser.add_argument("--json", dest="extra_json", help="extra params as a JSON object")
    parser.add_argument("command")
    parser.add_argument("params", nargs="*", metavar="key=value")
    args = parser.parse_args()

    path = discover(args)
    if args.wait:
        deadline = time.monotonic() + args.wait
        while path is None and time.monotonic() < deadline:
            time.sleep(0.2)
            path = discover(args)
        wait_for(path, max(deadline - time.monotonic(), 0))
    if path is None:
        sys.exit("no running debug Plume found; pass --socket, or launch one with the Debug build")

    request = {"id": str(int(time.time() * 1000)), "command": args.command}
    request.update(build_params(args.params, args.extra_json))

    before = frontmost() if args.assert_frontmost else None
    response = send(path, request)
    after = frontmost() if args.assert_frontmost else None

    if args.command == "hierarchy" and not args.raw and response.get("ok") and isinstance(response.get("result"), dict) and response["result"].get("text"):
        print(response["result"]["text"])
    else:
        print(json.dumps(response, indent=2, ensure_ascii=False))

    if args.assert_frontmost and before != after:
        sys.exit(f"frontmost app changed:\n  before: {before}\n  after:  {after}")
    if not response.get("ok"):
        sys.exit(1)


if __name__ == "__main__":
    main()
