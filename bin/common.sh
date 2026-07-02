#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../config/smolvm-env.sh"

OPENCODE_AUTH="$HOME/.local/share/opencode/auth.json"
CLAUDE_AUTH="$HOME/.local/share/claude-code/auth.json"

VOLUME_ARGS=(-v "$PWD:/workspace")
if [[ -d "${OPENCODE_AUTH%/*}" ]]; then
  VOLUME_ARGS+=(-v "${OPENCODE_AUTH%/*}:/mnt/opencode-auth:ro")
fi
if [[ -d "${CLAUDE_AUTH%/*}" ]]; then
  VOLUME_ARGS+=(-v "${CLAUDE_AUTH%/*}:/mnt/claude-auth:ro")
fi

_machine_exists() {
  smolvm machine ls --json 2>/dev/null | grep -q "\"name\": \"$MACHINE_NAME\""
}

_machine_is_running() {
  local status
  status=$(smolvm machine status --name "$MACHINE_NAME" --json 2>/dev/null || echo "{}")
  echo "$status" | grep -qi '"running"'
}

# Machine creation lives in ./setup (it needs Docker + the registry + a
# source VM to pack from) -- this just ensures the already-created machine
# has the right /workspace mount for wherever you're calling vm-* from.
_ensure_machine() {
  if ! _machine_exists; then
    echo "Machine '$MACHINE_NAME' doesn't exist yet. Run ./setup first." >&2
    exit 1
  fi

  local state_file="/tmp/smolvm-${MACHINE_NAME}.mount"
  local last_mount
  last_mount=$(cat "$state_file" 2>/dev/null || echo "")

  if [[ "$last_mount" != "$PWD" ]]; then
    if _machine_is_running; then
      smolvm machine stop --name "$MACHINE_NAME"
    fi
    smolvm machine update --name "$MACHINE_NAME" "${VOLUME_ARGS[@]}"
    echo "$PWD" > "$state_file"
  fi
}

# Best-effort: symlink host auth into place if the mounts are present. Runs
# on every vm_run (not just at create time) so refreshed host auth picks up
# without needing a VM restart.
_sync_auth() {
  smolvm machine exec --name "$MACHINE_NAME" -e "HOME=$DEV_HOME" -- sh -c '
    if [ -f /mnt/opencode-auth/auth.json ]; then
      mkdir -p "$HOME/.local/share/opencode"
      ln -sf /mnt/opencode-auth/auth.json "$HOME/.local/share/opencode/auth.json"
    fi
    if [ -f /mnt/claude-auth/auth.json ]; then
      KEY=$(jq -r .apiKey /mnt/claude-auth/auth.json 2>/dev/null)
      if [ -n "$KEY" ] && [ "$KEY" != "null" ]; then
        echo "$KEY" > /tmp/.claude-api-key
      fi
    fi
  ' >/dev/null 2>&1 || true
}

# Runs "$@" interactively inside the machine, with /workspace = $PWD.
#
# Explicit PATH/HOME: smolvm's ad-hoc exec containers run as root with a
# bare-bones PATH rather than the image's configured `dev` user/env (see
# FASTEST_APPROACH.md) -- without this, none of the tools installed for
# `dev` (node, opencode, claude, zig, ...) would resolve.
vm_run() {
  _ensure_machine
  if ! _machine_is_running; then
    smolvm machine start --name "$MACHINE_NAME"
  fi
  _sync_auth
  exec smolvm machine exec --name "$MACHINE_NAME" -it \
    -e "PATH=$DEV_PATH" -e "HOME=$DEV_HOME" -w /workspace -- "$@"
}
