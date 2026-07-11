#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../config/smolvm-env.sh"

OPENCODE_AUTH="$HOME/.local/share/opencode/auth.json"

# Static across every directory's machine (unlike /workspace, which is set
# per-machine at claim time). Read by lib-pool.sh via _finalize_claimed_machine.
AUTH_VOLUME_ARGS=()
if [[ -d "${OPENCODE_AUTH%/*}" ]]; then
  AUTH_VOLUME_ARGS+=(-v "${OPENCODE_AUTH%/*}:/mnt/opencode-auth:ro")
fi

_machine_is_running() {
  local name="$1" status
  status=$(smolvm machine status --name "$name" --json 2>/dev/null || echo "{}")
  echo "$status" | grep -qi '"running"'
}

# Best-effort: symlink host opencode auth into place if the mount is present.
# Runs on every vm_run so refreshed host auth picks up without a VM restart.
_sync_auth() {
  local name="$1"
  smolvm machine exec --name "$name" -- su - dev -c '
    if [ -f /mnt/opencode-auth/auth.json ]; then
      mkdir -p "$HOME/.local/share/opencode"
      ln -sf /mnt/opencode-auth/auth.json "$HOME/.local/share/opencode/auth.json"
    fi
  ' >/dev/null 2>&1 || true
}

# ===== Public API ============================================================
# Functions below are called by the vm-* scripts. Everything above is internal
# and _-prefixed.

# Runs "$@" interactively inside the machine dedicated to $PWD -- claiming a
# warm spare (or creating one) the first time this directory is used, reusing
# the same machine every time after.
#
# smolvm exec runs as root at the VM level, so we drop to `dev` ourselves via
# `su -` (sudo fails: pack extraction on macOS leaves files host-owned, which
# trips sudo's /etc/sudoers ownership check). `su -` resets env, so COLORTERM
# is passed through explicitly to keep 24-bit color working in nvim/bat/delta.
vm_run() {
  local machine cmd
  machine="$(resolve_machine_for_cwd)"
  if ! _machine_is_running "$machine"; then
    smolvm machine start --name "$machine"
  fi
  _sync_auth "$machine"
  printf -v cmd '%q ' "$@"
  exec smolvm machine exec --name "$machine" -e "COLORTERM=${COLORTERM:-}" -it -- \
    su --whitelist-environment=COLORTERM - dev -c "cd /workspace && $cmd"
}
