# smolvm-wrapper

Quickly launch opencode, claude, or a shell in an isolated [smolvm](https://github.com/smol-machines/smolvm) microVM, with the current directory mounted in. Similar to my [docker-sandbox cli wrapper](https://github.com/rasmus105/docker-sandbox).

Uses a persistent VM booted from a portable `.smolmachine` pack, which is what gets this under 1 second per launch (0.45s start, 0.16s exec) instead of the 30-90s a naive image pull/merge would cost. See `FASTEST_APPROACH.md` for the full story, numbers, and the exact bugs this depends on being fixed.

## Prerequisites

- **A patched smolvm build.** Stock smolvm 1.3.8 has real bugs that break this
  setup (layer-merge crash, an exec hang, and silently-dropped egress flags on
  `machine create --from`). You need a build from `~/dev/public/smolvm`
  (branch `fix/packed-layers-exec-hang`) instead of the official installer,
  until these land upstream. One-time setup:
  ```bash
  cd ~/dev/public/smolvm
  git checkout fix/packed-layers-exec-hang

  # Host CLI (needs `brew install libkrun` first)
  RUSTFLAGS="-L /opt/homebrew/lib" cargo build --release --bin smolvm
  codesign --force --sign - --entitlements smolvm.entitlements ./target/release/smolvm

  # Guest agent (cross-compiled via smolvm itself -- see script for details)
  bash scripts/build-agent-rootfs.sh target/agent-rootfs-debug
  ```
  See `FASTEST_APPROACH.md` for why the build has to happen this way, and
  what to do if it errors partway through running a VM (a known Homebrew
  libkrun version-mismatch failure mode).
- [Docker](https://docs.docker.com/engine/install/) (for building the agent image and running the local registry)

By default the scripts here look for the patched build at
`~/dev/public/smolvm/target/release/smolvm`. Override with `SMOLVM_SRC_DIR`
or `SMOLVM_BIN`/`SMOLVM_AGENT_ROOTFS` (see `config/smolvm-env.sh`) if yours
lives elsewhere.

## One-time setup

```bash
# Builds images/agent.Dockerfile, packs it, and creates the persistent
# `dev-box` machine from that pack. Takes a few minutes.
./setup

# Link wrapper scripts to your PATH
ln -sf $(pwd)/bin/vm-opencode ~/.local/bin/vm-opencode
ln -sf $(pwd)/bin/vm-claude   ~/.local/bin/vm-claude
ln -sf $(pwd)/bin/vm-shell    ~/.local/bin/vm-shell
ln -sf $(pwd)/bin/vm-reset    ~/.local/bin/vm-reset
```

Re-run `./setup` any time you change `images/agent.Dockerfile` or the
[dotfiles repo](https://github.com/rasmus105/dotfiles-ubuntu) it pulls from
— it always builds fresh and replaces the running `dev-box` machine.

## Usage

```bash
cd ~/git/my-project/

vm-opencode   # Launch opencode
vm-claude     # Launch claude-code
vm-shell      # Interactive shell
```

Each of these starts `dev-box` if it isn't already running (fast after the
first time) and mounts your current directory at `/workspace` inside the VM
— switching directories between calls just remounts, no rebuild needed.

`dev-box` is **persistent**: state written inside it (installed packages,
scratch files outside `/workspace`, etc.) survives across sessions. Anything
you actually want to keep long-term belongs in `images/agent.Dockerfile`
instead — treat the running machine itself as disposable.

```bash
vm-reset   # Wipe accumulated VM state, recreate from the last-built pack (fast)
```

`vm-reset` does not rebuild the image — it's for discarding drift picked up
during sessions. Run `./setup` instead if you need the image itself rebuilt.

## How it fits together

- `images/agent.Dockerfile` — the dev environment (node, opencode, claude,
  zig, dotfiles, ...).
- `config/smolvm-env.sh` — shared settings (machine name, resource sizes,
  egress allowlist, patched-smolvm location). Sourced by every script below.
- `setup` — builds the Docker image, pushes it to a throwaway local registry,
  packs it into a portable `.smolmachine` (`build/dev-box.smolmachine*`), and
  (re)creates the persistent `dev-box` machine from that pack.
- `bin/common.sh` — shared logic for the `vm-*` scripts: ensures `dev-box` is
  running with the right `/workspace` mount for the current directory, then
  execs into it.
- `bin/vm-shell`, `bin/vm-opencode`, `bin/vm-claude` — thin wrappers over
  `common.sh`'s `vm_run`.
- `bin/vm-reset` — deletes and recreates `dev-box` from the existing pack.
