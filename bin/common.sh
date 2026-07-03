#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../config/smolvm-env.sh"

OPENCODE_AUTH="$HOME/.local/share/opencode/auth.json"

# Static across every directory's machine (unlike /workspace, which is set
# per-machine at claim time in resolve_machine_for_cwd) -- read by lib-pool.sh.
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
# Runs on every vm_run (not just at claim time) so refreshed host auth picks
# up without needing a VM restart.
_sync_auth() {
  local name="$1"
  smolvm machine exec --name "$name" -- su - dev -c '
    if [ -f /mnt/opencode-auth/auth.json ]; then
      mkdir -p "$HOME/.local/share/opencode"
      ln -sf /mnt/opencode-auth/auth.json "$HOME/.local/share/opencode/auth.json"
    fi
  ' >/dev/null 2>&1 || true
}

# Runs "$@" interactively inside the machine dedicated to $PWD -- claiming a
# warm spare from the pool (or creating one if the pool's empty) the first
# time this directory is used, reusing the same machine every time after.
#
# smolvm's ad-hoc exec containers run as root at the VM level (there's no
# --user flag), not as the image's configured `dev` user -- so we drop
# privileges ourselves. `su` (not sudo -- pack extraction on macOS leaves
# every file host-user-owned rather than root:root, which fails sudo's
# ownership hardening check on /etc/sudoers) via a real login shell, which
# also means dotfiles' own PATH setup applies instead of us hand-maintaining
# one. `su -` chdirs to dev's $HOME, so `/workspace` is restored explicitly.
vm_run() {
  local machine cmd
  machine="$(resolve_machine_for_cwd)"
  if ! _machine_is_running "$machine"; then
    smolvm machine start --name "$machine"
  fi
  _sync_auth "$machine"
  printf -v cmd '%q ' "$@"
  exec smolvm machine exec --name "$machine" -it -- su - dev -c "cd /workspace && $cmd"
}
