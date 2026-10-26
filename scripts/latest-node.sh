#!/usr/bin/env bash
# Prints the newest Node.js 24 LTS release listed in https://nodejs.org/dist/index.json.
# With --security, prints whether that release is marked as a security release (true|false).
set -euo pipefail
curl -fsSL --retry 3 https://nodejs.org/dist/index.json | jq -r --arg field "${1:-}" '
  [.[] | select(.version | startswith("v24.")) | select(.lts)][0]
  | if $field == "--security" then .security else .version | ltrimstr("v") end'
