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
    iputils-ping \
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

# Matches the host user's uid/gid (see setup) -- smolvm's pack extraction on
# macOS is unprivileged, so a chown to any *other* uid/gid silently fails and
# the file just keeps the extracting host user's ownership. Making `dev` that
# same uid/gid turns those chowns into no-ops, so dev's own files actually
# land owned by dev instead of unwritable by anyone but the host user.
ARG HOST_UID=1000
ARG HOST_GID=1000
RUN (groupadd -g "$HOST_GID" devhost 2>/dev/null || true) && \
    useradd -m -u "$HOST_UID" -g "$HOST_GID" -s /bin/bash dev && \
    echo "dev ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

USER dev
WORKDIR /home/dev

RUN NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
ENV PATH="/home/linuxbrew/.linuxbrew/bin:/home/linuxbrew/.linuxbrew/sbin:/home/dev/.cargo/bin:${PATH}"

# smolvm caps OCI layer export at 4GiB uncompressed -- zig drags in LLVM+binutils+gcc
# (~3.3GB), so it gets its own layer. Add other large packages the same way.
RUN brew install zig && rm -rf "$(brew --cache)" "$HOME/.cache/Homebrew"

# zsh -i forces .zshrc to be sourced even with no TTY, which is what triggers
# antidote's one-time plugin clone (see home/.zsh/shell.zsh) -- without this
# it happens on your first real vm-shell instead.
#
# The nvim warmup opens a real buffer (not just +qa) because mason/blink.cmp
# only load on BufReadPost/BufNewFile (see config/nvim/lua/config/lsp.lua) --
# `sleep 90` gives their background installs (LSP servers, blink's fuzzy-
# matcher download) time to finish while the build still has full network
# access, instead of stalling on egress-filtered hosts on first real use.
RUN git clone https://github.com/rasmus105/dotfiles-ubuntu /home/dev/.dotfiles && \
    cd /home/dev/.dotfiles && bash setup.sh && \
    zsh -ilc 'exit' 2>/dev/null; \
    brew install node && \
    echo 'return 1' > /tmp/warmup.lua && \
    nvim --headless -c 'edit /tmp/warmup.lua' -c 'sleep 90' +qa 2>/dev/null; \
    rm -rf "$(brew --cache)" "$HOME/.cache/Homebrew"

RUN npm install -g \
    opencode-ai \
    @anthropic-ai/claude-code \
    typescript \
    typescript-language-server \
    && npm cache clean --force

# Overrides the dotfiles-managed defaults.
COPY --chown=dev:dev config/opencode.json /home/dev/.config/opencode/opencode.json
COPY --chown=dev:dev config/tui.json /home/dev/.config/opencode/tui.json

WORKDIR /workspace
