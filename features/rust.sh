#!/bin/bash
# features/rust.sh — Install Rust development environment
set -euo pipefail

echo "=== Installing Rust feature ==="

# Install C toolchain required for compiling Rust crates
apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

export RUSTUP_HOME=/usr/local/rustup
export CARGO_HOME=/usr/local/cargo

# Install rustup and stable toolchain
# Pin to stable channel — run 'rustup update' inside container for newer versions
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | \
    sh -s -- -y --default-toolchain stable --profile minimal

# Make cargo/rustup available to all users
chmod -R a+rw "$RUSTUP_HOME" "$CARGO_HOME"
echo 'export RUSTUP_HOME=/usr/local/rustup' >> /etc/profile.d/rust.sh
echo 'export CARGO_HOME=/usr/local/cargo' >> /etc/profile.d/rust.sh
echo 'export PATH="$CARGO_HOME/bin:$PATH"' >> /etc/profile.d/rust.sh

# Source for this session
export PATH="$CARGO_HOME/bin:$PATH"

# Install cargo tools — pinned to major.minor for patch fixes
cargo install cargo-watch@8 cargo-edit@0.13

# Firewall domains
mkdir -p /etc/sandbox/firewall.d
cat > /etc/sandbox/firewall.d/rust.conf <<'EOF'
static.rust-lang.org
crates.io
static.crates.io
EOF

echo "=== Rust feature installed ==="
