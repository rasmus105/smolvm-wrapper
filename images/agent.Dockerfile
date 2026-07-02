FROM ubuntu:26.04

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    ccache \
    clang \
    cmake \
    curl \
    file \
    g++ \
    gdb \
    git \
    jq \
    less \
    locales \
    ninja-build \
    openssh-client \
    pkg-config \
    python3 \
    python3-pip \
    python3-venv \
    rsync \
    sudo \
    unzip \
    xz-utils \
    zip \
    zlib1g-dev \
    && locale-gen en_US.UTF-8 \
    && update-locale LANG=en_US.UTF-8 \
    && rm -rf /var/lib/apt/lists/*

ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8
ENV TERM=xterm-256color

RUN useradd -m -s /bin/bash dev && \
    echo "dev ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

USER dev
WORKDIR /home/dev

# smolvm caps OCI layer export at 4GiB uncompressed. zig (in the dotfiles
# Brewfile) drags in llvm+binutils+gcc (~3.3GB on its own), which pushes the
# dotfiles setup layer past that cap. Install it standalone first so it lands
# in its own layer; `brew bundle` in setup.sh below then sees it satisfied
# and skips reinstalling it.
RUN NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" && \
    export PATH="/home/linuxbrew/.linuxbrew/bin:/home/linuxbrew/.linuxbrew/sbin:$PATH" && \
    brew install zig && \
    rm -rf "$(brew --cache)" "$HOME/.cache/Homebrew"

# dotfiles' setup.sh stows its own config/opencode files (AGENTS.md, tui.json)
# into ~/.config/opencode via symlinks. Everything that touches that directory
# happens in this single layer, so later COPYs below only ever add to it
# instead of flipping it between a plain dir and a stow symlink target across
# layers (that type flip is what broke smolvm's layer merge).
RUN git clone https://github.com/rasmus105/dotfiles-ubuntu /home/dev/.dotfiles && \
    cd /home/dev/.dotfiles && bash setup.sh && \
    export PATH="/home/linuxbrew/.linuxbrew/bin:/home/linuxbrew/.linuxbrew/sbin:$PATH" && \
    brew install node && \
    nvim --headless +qa 2>/dev/null; \
    rm -rf "$(brew --cache)" "$HOME/.cache/Homebrew"

ENV PATH="/home/linuxbrew/.linuxbrew/bin:/home/linuxbrew/.linuxbrew/sbin:/home/dev/.cargo/bin:${PATH}"

# install development stuff
RUN npm install -g \
    opencode-ai \
    @anthropic-ai/claude-code \
    typescript \
    typescript-language-server \
    && npm cache clean --force

# local stuff to copy into the image (overrides the dotfiles-managed defaults)
COPY --chown=dev:dev config/opencode.json /home/dev/.config/opencode/opencode.json
COPY --chown=dev:dev config/tui.json /home/dev/.config/opencode/tui.json

WORKDIR /workspace
