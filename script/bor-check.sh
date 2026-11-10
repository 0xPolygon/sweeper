#!/usr/bin/env bash
# Usage: script/bor-check.sh <recovery-address> [bor-tag]
# Runs test/bor/sweeper_core_test.go inside bor's core package (default tag v2.11.0).
set -euo pipefail
RECOVERY="${1:?usage: $0 <recovery-address> [bor-tag]}"
TAG="${2:-v2.11.0}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/cache/bor-$TAG"

if [ ! -d "$WORK" ]; then
  git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$TAG" https://github.com/0xPolygon/bor "$WORK"
fi
cp "$ROOT/test/bor/sweeper_core_test.go" "$WORK/core/zz_sweeper_core_test.go"

RUNTIME="$("$ROOT/script/runtime-code.sh" "$RECOVERY" | awk '/^runtime:/ {print $2}')"
cd "$WORK"
SWEEPER_RUNTIME="$RUNTIME" SWEEPER_RECOVERY="$RECOVERY" GOMAXPROCS="${GOMAXPROCS:-2}" GOMEMLIMIT="${GOMEMLIMIT:-3GiB}" \
  go test -p 2 ./core -run 'TestSweeper' -count=1 -v 2>&1 | grep -E '^(=== RUN|--- |    |ok|FAIL|PASS)'
