#!/usr/bin/env bash
set -euo pipefail

VM_IMAGE="${VM_IMAGE:-localhost:5000/smolvm-agent:latest}"
VM_CPUS="${VM_CPUS:-4}"
VM_MEM="${VM_MEM:-4096}"
MACHINE_NAME="smolvm-agent"

OPENCODE_AUTH="$HOME/.local/share/opencode/auth.json"
CLAUDE_AUTH="$HOME/.local/share/claude-code/auth.json"

ALLOWED_HOSTS=(
  "localhost"
  "api.anthropic.com"
  "api.openai.com"
  "openrouter.ai"
  "models.dev"
  "github.com"
  "api.github.com"
  "raw.githubusercontent.com"
  "registry.npmjs.org"
  "archive.ubuntu.com"
  "security.ubuntu.com"
)

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

_ensure_machine() {
  if ! _machine_exists; then
    local init_cmd='
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
    '
    local create_args=(--image "$VM_IMAGE" --cpus "$VM_CPUS" --mem "$VM_MEM" --net)
    for h in "${ALLOWED_HOSTS[@]}"; do
      create_args+=(--allow-host "$h")
    done
    [[ -n "${SSH_AUTH_SOCK:-}" ]] && create_args+=(--ssh-agent)
    smolvm machine create "${create_args[@]}" "${VOLUME_ARGS[@]}" --init "$init_cmd" "$MACHINE_NAME"
    return
  fi

  local state_file="/tmp/smolvm-${MACHINE_NAME}.mount"
  local last_mount
  last_mount=$(cat "$state_file" 2>/dev/null || echo "")

  if [[ "$last_mount" != "$PWD" ]]; then
    if _machine_is_running; then
      smolvm machine stop --name "$MACHINE_NAME" 2>/dev/null || true
    fi
    smolvm machine update "$MACHINE_NAME" "${VOLUME_ARGS[@]}" 2>/dev/null || true
    echo "$PWD" > "$state_file"
  fi
}

vm_run() {
  _ensure_machine
  if ! _machine_is_running; then
    smolvm machine start --name "$MACHINE_NAME"
  fi
  exec smolvm machine exec --name "$MACHINE_NAME" -it -- "$@"
}
