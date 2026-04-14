#!/bin/bash
# features/node-extra.sh — Install additional Node.js tooling
set -euo pipefail

echo "=== Installing node-extra feature ==="

# pnpm — pinned to major version for patch fixes without breaking changes
npm install -g pnpm@10

# yarn (--force in case a version is already present in the base image)
npm install -g --force yarn@1.22

# tsx (run TypeScript directly)
npm install -g tsx@4

# npm-check-updates
npm install -g npm-check-updates@17

npm cache clean --force

echo "=== node-extra feature installed ==="
