#!/usr/bin/env bash
# Shared configuration for smolvm-wrapper scripts. Source this, don't execute it.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# --- Patched smolvm build ---
# Stock smolvm 1.3.8 has real bugs that break the fast-boot path this wrapper
# depends on (layer merge crash, exec hang, dropped egress flags on
# `machine create --from`). See FASTEST_APPROACH.md for the full story and
# exact build steps. SMOLVM_SRC_DIR must point at that fork, already built.
SMOLVM_SRC_DIR="${SMOLVM_SRC_DIR:-$HOME/dev/public/smolvm}"
SMOLVM_BIN="${SMOLVM_BIN:-$SMOLVM_SRC_DIR/target/release/smolvm}"
export SMOLVM_AGENT_ROOTFS="${SMOLVM_AGENT_ROOTFS:-$SMOLVM_SRC_DIR/target/agent-rootfs-debug}"

smolvm() {
  if [[ ! -x "$SMOLVM_BIN" ]]; then
    echo "error: patched smolvm not found at $SMOLVM_BIN" >&2
    echo "See FASTEST_APPROACH.md for how to build it, or set SMOLVM_BIN." >&2
    exit 1
  fi
  "$SMOLVM_BIN" "$@"
}

# --- Machine / image identity ---
MACHINE_NAME="${MACHINE_NAME:-dev-box}"
SOURCE_MACHINE_NAME="${SOURCE_MACHINE_NAME:-dev-box-source}"
IMAGE_TAG="${IMAGE_TAG:-smolmachines-dev:latest}"
BUILD_DIR="$REPO_ROOT/build"
PACK_FILE="$BUILD_DIR/dev-box.smolmachine"
PACK_SIDECAR="$PACK_FILE.smolmachine"

# --- Resources for the source VM (setup) and the final machine ---
VM_CPUS="${VM_CPUS:-4}"
VM_MEM="${VM_MEM:-8192}"
VM_STORAGE_GB="${VM_STORAGE_GB:-40}"
VM_OVERLAY_GB="${VM_OVERLAY_GB:-8}"

# --- Egress allowlist: hosts the workload is allowed to reach ---
ALLOWED_HOSTS=(
  github.com
  api.github.com
  raw.githubusercontent.com
  registry.npmjs.org
  archive.ubuntu.com
  security.ubuntu.com
  api.anthropic.com
  api.openai.com
  openrouter.ai
  models.dev
)

# images/agent.Dockerfile's ENV PATH and dotfiles are configured for the
# `dev` user, but smolvm's ad-hoc exec containers always run as root with a
# bare-bones PATH and don't inherit the image's configured user/env (a
# pre-existing smolvm behavior -- see FASTEST_APPROACH.md). Set these
# explicitly on every exec so tools installed for `dev` still resolve.
DEV_PATH="/home/linuxbrew/.linuxbrew/bin:/home/linuxbrew/.linuxbrew/sbin:/home/dev/.cargo/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
DEV_HOME="/home/dev"
