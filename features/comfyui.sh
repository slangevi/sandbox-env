#!/bin/bash
# features/comfyui.sh — install the comfy helper for driving a ComfyUI instance
set -euo pipefail

echo "=== Installing ComfyUI feature ==="

# curl and jq come from the base image. Checked rather than installed so this
# feature never depends on the python feature the way llm does.
for tool in curl jq; do
    if ! command -v "$tool" &>/dev/null; then
        echo "ERROR: comfyui feature requires '$tool', which the base image provides."
        exit 1
    fi
done

install -m 0755 /tmp/comfyui.d/comfy /usr/local/bin/comfy

# Inert here (this feature installs no packages), but the feature contract in
# CLAUDE.md and README lists it as mandatory — kept so the contract holds for
# every feature script, including one that later grows an apt-get.
rm -rf /var/lib/apt/lists/*

# No /etc/sandbox/firewall.d/comfyui.conf: the target is an IP on a Docker
# network, not a resolvable domain. The CLI passes it via SANDBOX_COMFYUI_IP.

echo "=== ComfyUI feature installed ==="
