#!/usr/bin/env bash
# Spare-pool: gives every directory its own machine without paying the pack
# extraction cost on every new one. Sourced by config/smolvm-env.sh.

_pwd_hash() {
  local dir
  dir="$(cd "${1:-$PWD}" && pwd -P)" # realpath'd so "." and its absolute path match
  printf '%s' "$dir" | shasum -a 256 | cut -c1-8
}

# mkdir is atomic and needs no extra binary (no flock(1) on macOS by default).
# Breaks a lock older than $stale_after_secs so a crashed holder can't wedge
# things forever, and gives up after $max_wait_secs.
_with_lock() {
  local lock_dir="$1" stale_after_secs="$2" max_wait_secs="$3"
  shift 3
  local start
  start=$(date +%s)
  while ! mkdir "$lock_dir" 2>/dev/null; do
    local age=$(( $(date +%s) - $(stat -f %m "$lock_dir" 2>/dev/null || echo 0) ))
    if (( age > stale_after_secs )); then
      echo "warning: breaking stale lock at $lock_dir (${age}s old)" >&2
      rmdir "$lock_dir" 2>/dev/null || true
      continue
    fi
    if (( $(date +%s) - start >= max_wait_secs )); then
      echo "error: timed out waiting for the lock at $lock_dir" >&2
      return 1
    fi
    sleep 0.2
  done
  "$@"
  local status=$?
  rmdir "$lock_dir" 2>/dev/null || true
  return $status
}

# Claiming only does a quick file read-modify-write, so keep this tight.
_with_pool_lock() {
  _with_lock "$POOL_LOCK_DIR" 30 10 "$@"
}

# Replenishing can take minutes (real `machine create` calls) and must
# serialize with itself, so both thresholds are far more generous.
_with_replenish_lock() {
  _with_lock "$REPLENISH_LOCK_DIR" 600 600 "$@"
}

# Pool machine names, claimed or not -- claiming never renames a machine.
_pool_machine_names() {
  smolvm machine ls --json 2>/dev/null |
    jq -r --arg prefix "$POOL_PREFIX" '.[] | select(.name | startswith($prefix)) | .name'
}

_assigned_machine_for_hash() {
  [[ -f "$ASSIGNMENTS_FILE" ]] || return 0
  awk -F'\t' -v h="$1" '$1 == h { print $2; exit }' "$ASSIGNMENTS_FILE"
}

# Both require the pool lock held (read-modify-write of the whole file).
_record_assignment() {
  local hash="$1" machine="$2" dir="$3" tmp
  tmp="$(mktemp "$STATE_DIR/assignments.XXXXXX")"
  [[ -f "$ASSIGNMENTS_FILE" ]] && awk -F'\t' -v h="$hash" '$1 != h' "$ASSIGNMENTS_FILE" > "$tmp"
  printf '%s\t%s\t%s\n' "$hash" "$machine" "$dir" >> "$tmp"
  mv "$tmp" "$ASSIGNMENTS_FILE"
}
_remove_assignment() {
  [[ -f "$ASSIGNMENTS_FILE" ]] || return 0
  local tmp
  tmp="$(mktemp "$STATE_DIR/assignments.XXXXXX")"
  awk -F'\t' -v h="$1" '$1 != h' "$ASSIGNMENTS_FILE" > "$tmp"
  mv "$tmp" "$ASSIGNMENTS_FILE"
}

# First unassigned pool machine, if any. Caller must hold the pool lock.
_unclaimed_spare() {
  local assigned=""
  [[ -f "$ASSIGNMENTS_FILE" ]] && assigned=$(awk -F'\t' '{print $2}' "$ASSIGNMENTS_FILE")
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    grep -qxF "$name" <<< "$assigned" || { echo "$name"; return 0; }
  done < <(_pool_machine_names)
}

_next_pool_name() {
  local n
  n=$(cat "$POOL_COUNTER_FILE" 2>/dev/null || echo 0)
  echo $((n + 1)) > "$POOL_COUNTER_FILE"
  echo "${POOL_PREFIX}${n}"
}

# Extracted and ready, but unstarted and unmounted. No lock needed for the
# slow part (extraction touches no shared state; only naming does).
_create_pool_spare() {
  local name
  name="$(_with_pool_lock _next_pool_name)"
  local ssh_agent_args=()
  [[ -n "${SSH_AUTH_SOCK:-}" ]] && ssh_agent_args+=(--ssh-agent)
  smolvm machine create --name "$name" --from "$PACK_SIDECAR" -s "$SMOLFILE" \
    "${ssh_agent_args[@]}" >/dev/null
  echo "$name"
}

_pool_deficit() {
  local assigned="" unclaimed=0
  [[ -f "$ASSIGNMENTS_FILE" ]] && assigned=$(awk -F'\t' '{print $2}' "$ASSIGNMENTS_FILE")
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    grep -qxF "$name" <<< "$assigned" || unclaimed=$((unclaimed + 1))
  done < <(_pool_machine_names)
  local deficit=$((POOL_SIZE - unclaimed))
  echo $(( deficit < 0 ? 0 : deficit ))
}

# Used by ./setup after a rebuild -- old spares were extracted from the
# now-stale pack. Claimed machines are untouched (vm-reset handles those).
discard_unclaimed_pool_spares() {
  local assigned=""
  [[ -f "$ASSIGNMENTS_FILE" ]] && assigned=$(awk -F'\t' '{print $2}' "$ASSIGNMENTS_FILE")
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    if ! grep -qxF "$name" <<< "$assigned"; then
      echo "  discarding stale spare: $name"
      smolvm machine delete --name "$name" -f >/dev/null 2>&1 || true
    fi
  done < <(_pool_machine_names)
}

# Recomputes the deficit only after the lock is held -- that's what lets
# concurrent replenish calls serialize instead of each seeing "need 2 more"
# off a stale snapshot and jointly over-provisioning.
_replenish_pool_locked() {
  local deficit
  deficit=$(_pool_deficit)
  for ((i = 0; i < deficit; i++)); do
    echo "  warming spare $((i + 1))/$deficit..."
    _create_pool_spare >/dev/null
  done
}

replenish_pool() {
  _with_replenish_lock _replenish_pool_locked
}

# Detached so a vm-* claim doesn't wait on it; serializes with other
# replenish calls via the lock rather than double-provisioning.
replenish_pool_background() {
  (replenish_pool >/dev/null 2>&1 &) 2>/dev/null
}

# Empty stdout (not an error) means "pool was empty" -- caller falls back to
# creating one itself outside the lock, so that doesn't block other claims
# behind a ~40s create.
_try_claim_spare_locked() {
  local hash="$1" dir="$2" spare
  spare="$(_unclaimed_spare)"
  [[ -z "$spare" ]] && return 0
  _record_assignment "$hash" "$spare" "$dir"
  echo "$spare"
}

# Claims (or creates) the machine for $PWD and prints its name. All other
# output goes to stderr so callers can capture just the name via $(...).
resolve_machine_for_cwd() {
  local dir hash machine
  dir="$(pwd -P)"
  hash="$(_pwd_hash "$dir")"

  machine="$(_assigned_machine_for_hash "$hash")"
  if [[ -n "$machine" ]] &&
    smolvm machine ls --json 2>/dev/null | jq -e --arg n "$machine" 'any(.[]; .name == $n)' >/dev/null
  then
    echo "$machine"
    return 0
  fi
  [[ -n "$machine" ]] && _with_pool_lock _remove_assignment "$hash" # stale assignment

  machine="$(_with_pool_lock _try_claim_spare_locked "$hash" "$dir")"
  if [[ -z "$machine" ]]; then
    echo "No warm spare available -- creating a new machine for this directory (one-time ~40s)..." >&2
    machine="$(_create_pool_spare)"
    _with_pool_lock _record_assignment "$hash" "$machine" "$dir"
  fi

  smolvm machine update --name "$machine" -v "$dir:/workspace" "${AUTH_VOLUME_ARGS[@]}" >/dev/null
  replenish_pool_background
  echo "$machine"
}
