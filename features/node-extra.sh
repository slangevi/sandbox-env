#!/bin/bash
# features/node-extra.sh — Install additional Node.js tooling
set -euo pipefail

echo "=== Installing node-extra feature ==="

# pnpm
npm install -g pnpm

# yarn (--force in case a version is already present in the base image)
npm install -g --force yarn

# tsx (run TypeScript directly)
npm install -g tsx

# npm-check-updates
npm install -g npm-check-updates

npm cache clean --force

echo "=== node-extra feature installed ==="
