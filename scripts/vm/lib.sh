# Shared by make-base-image.sh and plume-vm. docs/vm-testing.md is the reference.

VMS_DIR="$HOME/Library/Application Support/Plume/vms"
KEY="$VMS_DIR/id_ed25519"
GUEST_USER=admin

# Runs a command while holding every named lock, or exits 3 at once when any is held.
with_locks() {
  local count=$1
  shift
  perl -e 'use Fcntl ":flock"; my $n = shift; my @held;
    for (1 .. $n) { open(my $f, ">>", shift) or exit 2; flock($f, LOCK_EX | LOCK_NB) or exit 3; push @held, $f }
    system(@ARGV); exit($? == 0 ? 0 : 1)' "$count" "$@"
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
