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

COPY --chown=dev:dev opencode.json /home/dev/.config/opencode/opencode.json
COPY --chown=dev:dev tui.json /home/dev/.config/opencode/tui.json
COPY --chown=dev:dev opencode-instructions.md /home/dev/.config/opencode/opencode-instructions.md

USER dev
WORKDIR /home/dev

RUN git clone https://github.com/rasmus105/dotfiles-ubuntu /home/dev/.dotfiles && \
    cd /home/dev/.dotfiles && bash setup.sh

ENV PATH="/home/linuxbrew/.linuxbrew/bin:/home/linuxbrew/.linuxbrew/sbin:/home/dev/.cargo/bin:${PATH}"

RUN brew install node

RUN nvim --headless +qa 2>/dev/null || true

RUN npm install -g \
    opencode-ai \
    @anthropic-ai/claude-code \
    typescript \
    typescript-language-server

WORKDIR /workspace
