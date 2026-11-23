# Shared by make-base-image.sh and plume-vm. docs/vm-testing.md is the reference.

VMS_DIR="$HOME/Library/Application Support/Plume/vms"
KEY="$VMS_DIR/id_ed25519"
GUEST_USER=admin
VM_SLOTS=2

# Runs a command while holding every named lock, or exits 3 at once when any is held. Each lock
# file holds this process's VMCloneLock record (pid, start seconds, start microseconds) while held,
# since a Plume checking for a free clone reads the record instead of trying the lock.
with_locks() {
  local count=$1
  shift
  python3 -c "$WITH_LOCKS" "$count" "$@"
}

# shellcheck disable=SC2016
WITH_LOCKS='
import ctypes, fcntl, os, subprocess, sys

def start_time(pid):
    info = ctypes.create_string_buffer(136)  # struct proc_bsdinfo
    libc = ctypes.CDLL(None, use_errno=True)
    if libc.proc_pidinfo(pid, 3, ctypes.c_uint64(0), info, 136) != 136:  # PROC_PIDTBSDINFO
        return 0, 0
    return (int.from_bytes(info.raw[120:128], "little"), int.from_bytes(info.raw[128:136], "little"))

count = int(sys.argv[1])
paths, command = sys.argv[2:2 + count], sys.argv[2 + count:]
held = []
try:
    for path in paths:
        try:
            fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o644)
        except OSError:
            sys.exit(2)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            os.close(fd)
            sys.exit(3)
        held.append(fd)
    record = ("%d %d %d\n" % ((os.getpid(),) + start_time(os.getpid()))).encode()
    for fd in held:
        os.ftruncate(fd, 0)
        os.pwrite(fd, record, 0)
    child = subprocess.Popen(command)
    while True:
        try:
            status = child.wait()
            break
        except KeyboardInterrupt:
            pass
    sys.exit(0 if status == 0 else 1)
finally:
    for fd in held:
        os.ftruncate(fd, 0)
        fcntl.flock(fd, fcntl.LOCK_UN)
        os.close(fd)
'

# with_locks over every slot's clone lock for an OS, including slots that have no clone yet and any
# other plume-<os>-*.lock, so a slot count above VM_SLOTS can't leave one unlocked.
with_slot_locks() {
  local os=$1 n lock locks=()
  shift
  for n in $(seq 1 "$VM_SLOTS"); do locks+=("$VMS_DIR/plume-$os-$n.lock"); done
  for lock in "$VMS_DIR/plume-$os-"*.lock; do
    [[ -e "$lock" && " ${locks[*]} " != *" $lock "* ]] && locks+=("$lock")
  done
  with_locks "${#locks[@]}" "${locks[@]}" "$@"
}

# Deletes each plume-<os>-<n> clone under its clone lock, so a Plume booting one meanwhile keeps
# it and the app's next claim clones the current base. Warns about each clone it skipped.
delete_stale_clones() {
  local os=$1 clone skipped=()
  while IFS= read -r clone; do
    [[ "$clone" =~ ^plume-$os-[0-9]+$ ]] || continue
    if with_locks 1 "$VMS_DIR/$clone.lock" tart delete "$clone"; then
      echo "==> Deleted stale clone $clone"
    else
      skipped+=("$clone")
    fi
  done < <(tart list --source local -q)
  for clone in ${skipped[@]+"${skipped[@]}"}; do
    echo "warning: $clone is in use or could not be deleted, so it still has the old base; once it is free, run: plume devices reset vm:${clone##*-}" >&2
  done
}
