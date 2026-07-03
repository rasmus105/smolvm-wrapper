#!/usr/bin/env bash
# Shared config + the smolvm() wrapper function. Source, don't execute.
#
# VM-level settings (egress hosts, cpus/mem/storage/overlay) live in
# Smolfile.toml, not here -- everything below is wrapper-only stuff Smolfile
# has no concept of (pool bookkeeping, machine naming, where the patched
# smolvm build lives).

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SMOLFILE="$REPO_ROOT/Smolfile.toml"

# Needs a patched smolvm build -- see README.md.
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

# Each directory gets its own machine (see README), claimed from a pool of
# POOL_SIZE pre-warmed spares so a new directory doesn't pay the ~40s pack
# extraction cost inline.
POOL_SIZE="${POOL_SIZE:-3}"
POOL_PREFIX="${MACHINE_PREFIX}-pool-"

STATE_DIR="${STATE_DIR:-$HOME/.cache/smolvm-wrapper}"
mkdir -p "$STATE_DIR"
ASSIGNMENTS_FILE="$STATE_DIR/assignments.tsv"
POOL_COUNTER_FILE="$STATE_DIR/pool-counter"
POOL_LOCK_DIR="$STATE_DIR/pool.lock"
REPLENISH_LOCK_DIR="$STATE_DIR/replenish.lock"

source "$REPO_ROOT/bin/lib-pool.sh"

# smolvm's exec containers run as root with a bare PATH, not the image's
# `dev` user/env -- set these on every exec so installed tools resolve.
DEV_PATH="/home/linuxbrew/.linuxbrew/bin:/home/linuxbrew/.linuxbrew/sbin:/home/dev/.cargo/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
DEV_HOME="/home/dev"
