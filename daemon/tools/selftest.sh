#!/usr/bin/env bash
# Build the workspace and run the loopback self-test.
set -euo pipefail
cd "$(dirname "$0")/.."
if ! command -v cargo >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "$HOME/.cargo/env"
fi
cargo build
exec python3 tools/selftest.py
