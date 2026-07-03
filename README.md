# smolvm-wrapper

Launch opencode, claude-code, or a shell in an isolated [smolvm](https://github.com/smol-machines/smolvm)
microVM, with the current directory mounted in. Every directory gets its own
dedicated machine, so projects can't see each other's files even while
several run at once. Similar to [docker-sandbox](https://github.com/rasmus105/docker-sandbox).

## Dependencies

- A patched smolvm build (stock 1.3.8 has bugs that break this setup):
  ```bash
  cd ~/dev/public/smolvm  # TODO: push to git repo
  RUSTFLAGS="-L /opt/homebrew/lib" cargo build --release --bin smolvm  # needs `brew install libkrun`
  codesign --force --sign - --entitlements smolvm.entitlements ./target/release/smolvm
  bash scripts/build-agent-rootfs.sh target/agent-rootfs-debug
  ```
- [Docker](https://docs.docker.com/engine/install/) -- builds the agent image and runs a throwaway local registry.
- `jq`.

## One-time setup

```bash
./setup   # builds images/agent.Dockerfile, packs it, warms a pool of spare VMs

ln -sf $(pwd)/bin/vm-opencode ~/.local/bin/vm-opencode
ln -sf $(pwd)/bin/vm-claude   ~/.local/bin/vm-claude
ln -sf $(pwd)/bin/vm-shell    ~/.local/bin/vm-shell
ln -sf $(pwd)/bin/vm-reset    ~/.local/bin/vm-reset
```

Re-run `./setup` whenever `images/agent.Dockerfile` changes. It rebuilds the
pack and refreshes the spare pool, but directories that already claimed a
machine keep running their old one -- run `vm-reset` in those to update them.

## Usage

```bash
cd ~/dev/my-project/

vm-opencode   # Launch opencode
vm-claude     # Launch claude-code
vm-shell      # Interactive shell
vm-reset      # Wipe this directory's machine, claim a fresh one
```

The first run in a directory claims a machine for it -- a warm spare if the
pool has one (instant), otherwise a fresh one (~40s, one-time). Every run
after that reuses the same machine. Different directories always get
different machines, so they're fully isolated and can run concurrently; set
`POOL_SIZE` in `config/smolvm-env.sh` to how many you expect open at once.

Each machine is persistent -- installed packages and scratch files survive
across sessions. Anything worth keeping long-term belongs in
`images/agent.Dockerfile` instead. Allowed networks are defined in
`Smolfile.toml`. After changing `Smotfile.toml`, you must run `./setup` and
`vm-reset` for the changes to take effect.
