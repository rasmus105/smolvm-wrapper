#!/usr/bin/env bash
# Shared config + the smolvm() wrapper. Source, don't execute.
#
# VM-level settings (egress, cpus/mem/storage) live in Smolfile.toml; this
# file is wrapper-only stuff Smolfile has no concept of (pool bookkeeping,
# machine naming, where the patched smolvm build lives).

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SMOLFILE="$REPO_ROOT/Smolfile.toml"

# Patched smolvm build -- see README.md.
SMOLVM_SRC_DIR="${SMOLVM_SRC_DIR:-$HOME/dev/public/smolvm}"
SMOLVM_BIN="${SMOLVM_BIN:-$SMOLVM_SRC_DIR/target/release/smolvm}"
export SMOLVM_AGENT_ROOTFS="${SMOLVM_AGENT_ROOTFS:-$SMOLVM_SRC_DIR/target/agent-rootfs-debug}"

smolvm() {
  if [[ ! -x "$SMOLVM_BIN" ]]; then
    echo "error: patched smolvm not found at $SMOLVM_BIN (see README.md)" >&2
    exit 1
  fi
  "$SMOLVM_BIN" "$@"
}

MACHINE_PREFIX="${MACHINE_PREFIX:-dev-box}"
SOURCE_MACHINE_NAME="${SOURCE_MACHINE_NAME:-dev-box-source}"
IMAGE_TAG="${IMAGE_TAG:-smolmachines-dev:latest}"
BUILD_DIR="$REPO_ROOT/build"
PACK_FILE="$BUILD_DIR/dev-box.smolmachine"
PACK_SIDECAR="$PACK_FILE.smolmachine"

# Each directory gets its own machine, claimed from POOL_SIZE pre-warmed spares
# so a new directory doesn't pay the ~40s pack-extraction cost inline.
POOL_SIZE="${POOL_SIZE:-3}"
POOL_PREFIX="${MACHINE_PREFIX}-pool-"

STATE_DIR="${STATE_DIR:-$HOME/.cache/smolvm-wrapper}"
mkdir -p "$STATE_DIR"
ASSIGNMENTS_FILE="$STATE_DIR/assignments.tsv"
NEXT_MACHINE_ID_FILE="$STATE_DIR/next-machine-id"

# Locks are intentionally ephemeral. Persistent assignment state belongs above;
# locks belong in the per-user temporary directory and are also PID-validated.
LOCK_BASE="${TMPDIR:-/tmp}"
LOCK_BASE="${LOCK_BASE%/}"
LOCK_DIR="${LOCK_DIR:-$LOCK_BASE/smolvm-wrapper-$UID}"
mkdir -p "$LOCK_DIR"
chmod 700 "$LOCK_DIR"
POOL_LOCK_DIR="$LOCK_DIR/pool.lock"
REPLENISH_LOCK_DIR="$LOCK_DIR/replenish.lock"
SETUP_LOCK_DIR="$LOCK_DIR/setup.lock"
DIR_LOCK_PREFIX="$LOCK_DIR/directory-"

source "$REPO_ROOT/bin/lib-pool.sh"
