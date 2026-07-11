#!/usr/bin/env bash
# Spare-pool: gives every directory its own machine without paying the
# pack-extraction cost on every new one. Sourced by config/smolvm-env.sh.

# --- one-time state migrations (idempotent; run on every source) -----------

# Renamed for clarity; preserve the value if the old file is still around.
if [[ -f "$STATE_DIR/pool-counter" && ! -f "$NEXT_MACHINE_ID_FILE" ]]; then
  mv "$STATE_DIR/pool-counter" "$NEXT_MACHINE_ID_FILE"
fi
# v1 keyed assignments by a path hash (hash\tmachine\tdir); v2 keys by dir
# (dir\tmachine). A legacy file won't match the new lookup and would keep dead
# machines counted as assigned, so drop it and let dirs re-claim fresh spares.
if [[ -f "$ASSIGNMENTS_FILE" ]] && awk -F'\t' 'NF==3{f=1} END{exit !f}' "$ASSIGNMENTS_FILE"; then
  echo "note: resetting legacy pool assignments (format changed)" >&2
  rm -f "$ASSIGNMENTS_FILE"
fi

# --- locking --------------------------------------------------------------

# mkdir is atomic and needs no extra binary (no flock(1) on macOS). Lock owners
# are PID-validated, so a dead owner is reclaimed immediately instead of making
# callers wait for an arbitrary stale-age timeout.
_lock_owner_is_alive() {
  [[ "$1" =~ ^[0-9]+$ ]] && kill -0 "$1" 2>/dev/null
}

_with_lock() (
  local lock_dir="$1" stale_after_secs="$2" max_wait_secs="$3"
  shift 3
  local start owner_pid status operation last_report now elapsed age
  operation="${1:-operation}"
  start=$(date +%s)
  last_report=0
  while ! mkdir "$lock_dir" 2>/dev/null; do
    now=$(date +%s)
    age=$(( now - $(stat -f %m "$lock_dir" 2>/dev/null || echo 0) ))
    owner_pid=$(cat "$lock_dir/owner-pid" 2>/dev/null || true)
    if [[ -n "$owner_pid" ]] && ! _lock_owner_is_alive "$owner_pid"; then
      echo "warning: reclaiming lock at $lock_dir from dead PID $owner_pid" >&2
      rm -f "$lock_dir/owner-pid"
      rmdir "$lock_dir" 2>/dev/null || true
      continue
    fi
    if [[ -z "$owner_pid" ]] && (( age > stale_after_secs )); then
      echo "warning: reclaiming incomplete lock at $lock_dir (${age}s old)" >&2
      rmdir "$lock_dir" 2>/dev/null || true
      continue
    fi
    elapsed=$((now - start))
    if (( now - last_report >= 5 )); then
      if [[ -n "$owner_pid" ]]; then
        echo "waiting for $operation: lock held by PID $owner_pid for ${age}s ($lock_dir)" >&2
      else
        echo "waiting for $operation: lock is being acquired ($lock_dir)" >&2
      fi
      last_report=$now
    fi
    if (( elapsed >= max_wait_secs )); then
      echo "error: timed out waiting for the lock at $lock_dir" >&2
      return 1
    fi
    sleep 0.2
  done
  # macOS ships Bash 3.2, which lacks BASHPID. Write the child shell's PPID
  # directly: it is this Bash process, including when called via $(...).
  if ! sh -c '
    case "$PPID" in
      ""|*[!0-9]*) exit 1 ;;
    esac
    printf "%s\n" "$PPID" > "$1"
  ' sh "$lock_dir/owner-pid"
  then
    rm -f "$lock_dir/owner-pid"
    rmdir "$lock_dir" 2>/dev/null || true
    echo "error: could not record lock owner at $lock_dir" >&2
    return 1
  fi
  cleanup_lock() {
    status=$?
    rm -f "$lock_dir/owner-pid"
    rmdir "$lock_dir" 2>/dev/null || true
    exit "$status"
  }
  trap cleanup_lock EXIT
  # A callback such as setup may need its own EXIT trap. Keep it in a child so
  # it cannot replace the lock owner's cleanup trap.
  ( "$@" )
)

_with_pool_lock()      { _with_lock "$POOL_LOCK_DIR"       5 300 "$@"; }
_with_replenish_lock() { _with_lock "$REPLENISH_LOCK_DIR" 5 600 "$@"; }
_with_setup_lock()     { _with_lock "$SETUP_LOCK_DIR"     5 21600 "$@"; }

_directory_lock_dir() {
  local hash
  hash=$(printf '%s' "$1" | shasum -a 256 | cut -c1-16)
  printf '%s%s.lock\n' "$DIR_LOCK_PREFIX" "$hash"
}

_with_directory_lock() {
  local dir="$1"
  shift
  _with_lock "$(_directory_lock_dir "$dir")" 5 21600 "$@"
}

# --- pool queries ---------------------------------------------------------

# Pool machine names (claimed or not). Claiming never renames a machine.
_pool_machine_names() {
  smolvm machine ls --json 2>/dev/null |
    jq -r --arg prefix "$POOL_PREFIX" '.[] | select(.name | startswith($prefix)) | .name'
}

# Pool machines not currently assigned to any directory.
_unclaimed_pool_machines() {
  local assigned="" name
  [[ -f "$ASSIGNMENTS_FILE" ]] && assigned=$(awk -F'\t' '{print $2}' "$ASSIGNMENTS_FILE")
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    grep -qxF "$name" <<<"$assigned" || echo "$name"
  done < <(_pool_machine_names)
}

_unclaimed_spare() {
  local name
  while IFS= read -r name; do
    [[ -n "$name" ]] && { echo "$name"; return 0; }
  done < <(_unclaimed_pool_machines)
}

_pool_deficit() {
  local unclaimed=0
  while IFS= read -r _; do unclaimed=$((unclaimed + 1)); done < <(_unclaimed_pool_machines)
  local deficit=$((POOL_SIZE - unclaimed))
  echo $(( deficit < 0 ? 0 : deficit ))
}

# --- assignment file (all ops require the pool lock: read-modify-write) ---

_assigned_machine_for_dir() {
  [[ -f "$ASSIGNMENTS_FILE" ]] || return 0
  awk -F'\t' -v d="$1" '$1 == d { print $2; exit }' "$ASSIGNMENTS_FILE"
}
_record_assignment() {
  local dir="$1" machine="$2" tmp
  tmp="$(mktemp "$STATE_DIR/assignments.XXXXXX")"
  [[ -f "$ASSIGNMENTS_FILE" ]] && awk -F'\t' -v d="$dir" '$1 != d' "$ASSIGNMENTS_FILE" > "$tmp"
  printf '%s\t%s\n' "$dir" "$machine" >> "$tmp"
  mv "$tmp" "$ASSIGNMENTS_FILE"
}
_remove_assignment() {
  [[ -f "$ASSIGNMENTS_FILE" ]] || return 0
  local tmp
  tmp="$(mktemp "$STATE_DIR/assignments.XXXXXX")"
  awk -F'\t' -v d="$1" '$1 != d' "$ASSIGNMENTS_FILE" > "$tmp"
  mv "$tmp" "$ASSIGNMENTS_FILE"
}

# --- spare creation -------------------------------------------------------

# Monotonic unique-name counter -- NOT a live machine count; only increments,
# deletions don't decrement. Caller must hold the pool lock.
_next_pool_name() {
  local n
  n=$(cat "$NEXT_MACHINE_ID_FILE" 2>/dev/null || echo 0)
  echo $((n + 1)) > "$NEXT_MACHINE_ID_FILE"
  echo "${POOL_PREFIX}${n}"
}

# Extracts a fresh, unstarted spare from the pack. Callers may pass a name that
# was already reserved under the pool lock before the slow extraction begins.
_create_pool_spare() {
  local name="${1:-}"
  [[ -n "$name" ]] || name="$(_with_pool_lock _next_pool_name)"
  local ssh_agent_args=()
  [[ -n "${SSH_AUTH_SOCK:-}" ]] && ssh_agent_args+=(--ssh-agent)
  smolvm machine create --name "$name" --from "$PACK_SIDECAR" -s "$SMOLFILE" \
    "${ssh_agent_args[@]}" >/dev/null
  echo "$name"
}

# Applies per-directory mounts, kicks off background replenish, prints the name.
_finalize_claimed_machine() {
  local machine="$1" dir="$2"
  smolvm machine update --name "$machine" -v "$dir:/workspace" "${AUTH_VOLUME_ARGS[@]}" >/dev/null
  replenish_pool_background
  echo "$machine"
}

# Empty stdout (not error) means "pool empty" -- caller creates one itself,
# outside the lock, so a ~40s create doesn't block other claims behind it.
_try_claim_spare_locked() {
  local dir="$1" spare
  spare="$(_unclaimed_spare)"
  [[ -z "$spare" ]] && return 0
  _record_assignment "$dir" "$spare"
  echo "$spare"
}

_reserve_fresh_machine_locked() {
  local dir="$1" name
  name="$(_next_pool_name)"
  _record_assignment "$dir" "$name"
  echo "$name"
}

# Recomputes the deficit only after the lock is held, so concurrent replenish
# calls serialize instead of each seeing a stale "need N more" snapshot.
_replenish_pool_locked() {
  local deficit
  deficit=$(_pool_deficit)
  for ((i = 0; i < deficit; i++)); do
    echo "  warming spare $((i + 1))/$deficit..."
    _create_pool_spare >/dev/null
  done
}

# ===== Public API ============================================================
# Functions below are called by vm-* scripts and ./setup. Everything above is
# internal and _-prefixed.

# Claims (or creates) the machine for $PWD and prints its name. All other
# output goes to stderr so callers can capture just the name via $(...).
_resolve_machine_for_dir() {
  local dir="$1" machine

  machine="$(_assigned_machine_for_dir "$dir")"
  if [[ -n "$machine" ]] &&
    smolvm machine ls --json 2>/dev/null | jq -e --arg n "$machine" 'any(.[]; .name == $n)' >/dev/null
  then
    echo "$machine"
    return 0
  fi
  [[ -n "$machine" ]] && _with_pool_lock _remove_assignment "$dir" # stale

  machine="$(_with_pool_lock _try_claim_spare_locked "$dir")"
  if [[ -z "$machine" ]]; then
    echo "No warm spare available -- creating a new machine for this directory (one-time ~40s)..." >&2
    machine="$(_with_pool_lock _reserve_fresh_machine_locked "$dir")"
    _with_setup_lock _create_pool_spare "$machine" >/dev/null
  fi

  _finalize_claimed_machine "$machine" "$dir"
}

resolve_machine_for_cwd() {
  local dir
  dir="$(pwd -P)"
  _with_directory_lock "$dir" _resolve_machine_for_dir "$dir"
}

replenish_pool() {
  _with_setup_lock _with_replenish_lock _replenish_pool_locked
}

# Detached so a vm-* claim doesn't wait on it; serializes via the lock.
replenish_pool_background() {
  (replenish_pool >/dev/null 2>&1 &) 2>/dev/null
}

# Used by ./setup after a rebuild -- old spares came from the now-stale pack.
# Claimed machines are left alone; vm-rm removes one when it is no longer needed.
_discard_unclaimed_pool_spares_locked() {
  local name
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    echo "  discarding stale spare: $name"
    smolvm machine delete --name "$name" -f >/dev/null 2>&1 || true
  done < <(_unclaimed_pool_machines)
}

discard_unclaimed_pool_spares() {
  _with_pool_lock _discard_unclaimed_pool_spares_locked
}
