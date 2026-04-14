FROM node:20.19-slim

ARG CLAUDE_CODE_VERSION=2.1.104
ARG DEBIAN_FRONTEND=noninteractive
ENV TZ=UTC

# Core system packages
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    curl \
    wget \
    unzip \
    less \
    fzf \
    zsh \
    man-db \
    procps \
    gnupg2 \
    jq \
    nano \
    vim \
    iproute2 \
    dnsutils \
    iptables \
    ipset \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# aggregate tool for CIDR aggregation (used by firewall)
RUN apt-get update && apt-get install -y --no-install-recommends aggregate \
    && rm -rf /var/lib/apt/lists/* \
    || echo "aggregate not available, skipping"

# GitHub CLI
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    | tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
    && apt-get update && apt-get install -y gh \
    && rm -rf /var/lib/apt/lists/*
# gh version is managed by GitHub's apt repo — pinned upstream

# git-delta for better diffs
RUN ARCH=$(dpkg --print-architecture) && \
    if [ "$ARCH" = "amd64" ]; then DELTA_ARCH="x86_64"; else DELTA_ARCH="aarch64"; fi && \
    curl -fsSL "https://github.com/dandavison/delta/releases/download/0.18.2/delta-0.18.2-${DELTA_ARCH}-unknown-linux-gnu.tar.gz" \
    | tar xz -C /tmp && \
    mv /tmp/delta-*/delta /usr/local/bin/ && \
    rm -rf /tmp/delta-*

# gosu for privilege dropping in entrypoint
RUN curl -fsSL "https://github.com/tianon/gosu/releases/download/1.17/gosu-$(dpkg --print-architecture)" -o /usr/local/bin/gosu \
    && chmod +x /usr/local/bin/gosu \
    && gosu nobody true

# Claude Code CLI
# TODO: pin to specific version once stable release cadence is established
RUN npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}

# No broad sudo — entrypoint runs as root for firewall/services,
# then drops to node user. Sudo removed entirely for security.

# Create directories
RUN mkdir -p /workspace /etc/sandbox/firewall.d /commandhistory \
    && chown node:node /workspace /commandhistory

# Zsh setup with basic productivity config
RUN chsh -s /bin/zsh node
COPY --chown=node:node base/zshrc /home/node/.zshrc

# Firewall and entrypoint scripts
COPY base/firewall-domains.conf /etc/sandbox/firewall-domains.conf
COPY base/init-firewall.sh /usr/local/bin/init-firewall.sh
RUN chmod +x /usr/local/bin/init-firewall.sh
COPY base/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Environment
ENV DEVCONTAINER=true \
    SHELL=/bin/zsh \
    EDITOR=nano \
    VISUAL=nano

# Entrypoint runs as root to init firewall/services, then drops to node
# USER node  -- removed, entrypoint handles privilege drop
WORKDIR /workspace

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["/bin/zsh"]
