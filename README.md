# smolvm-wrapper

Quickly launch opencode, claude, or a shell in an isolated [smolvm](https://github.com/smol-machines/smolvm) microVM. Similar to my [docker-sandbox cli wrapper](https://github.com/rasmus105/docker-sandbox).

## Prerequisites

- [smolvm](https://github.com/smol-machines/smolvm): `curl -sSL https://smolmachines.com/install.sh | bash`
- [Docker](https://docs.docker.com/engine/install/) (for building the agent image and running the local registry)

## One-time setup

```bash
# Build image and push to a local Docker registry (nothing leaves your machine)
./setup

# Link wrapper scripts to your PATH
ln -sf $(pwd)/bin/vm-opencode ~/.local/bin/vm-opencode
ln -sf $(pwd)/bin/vm-claude   ~/.local/bin/vm-claude
ln -sf $(pwd)/bin/vm-shell    ~/.local/bin/vm-shell
ln -sf $(pwd)/bin/vm-reset    ~/.local/bin/vm-reset
```

## Usage

```bash
cd ~/git/my-project/

vm-opencode   # Launch opencode
vm-claude     # Launch claude-code
vm-shell      # Interactive shell
```
