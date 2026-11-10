#!/usr/bin/env bash
# Usage: script/runtime-code.sh <recovery-address>
# Prints the Sweeper(<recovery>) runtime bytecode, its size and keccak256.
set -euo pipefail

RECOVERY="${1:?usage: $0 <recovery-address>}"
RECOVERY="$(cast to-check-sum-address "$RECOVERY")"
PORT="${PORT:-8547}"
RPC="http://127.0.0.1:$PORT"

cd "$(dirname "$0")/.."
forge build --quiet

anvil --port "$PORT" --silent &
ANVIL_PID=$!
trap 'kill "$ANVIL_PID" 2>/dev/null || true' EXIT
for _ in $(seq 50); do cast chain-id --rpc-url "$RPC" >/dev/null 2>&1 && break; sleep 0.1; done

FROM="$(cast rpc --rpc-url "$RPC" eth_accounts | tr -d '[]" ' | cut -d, -f1)"
ADDR="$(forge create src/Sweeper.sol:Sweeper --rpc-url "$RPC" --unlocked --from "$FROM" --broadcast --json \
  --constructor-args "$RECOVERY" 2>/dev/null | jq -r .deployedTo)"

ONCHAIN_RECOVERY="$(cast call "$ADDR" "RECOVERY()(address)" --rpc-url "$RPC")"
[ "$ONCHAIN_RECOVERY" = "$RECOVERY" ] || { echo "RECOVERY mismatch: $ONCHAIN_RECOVERY" >&2; exit 1; }

CODE="$(cast code "$ADDR" --rpc-url "$RPC")"
echo "recovery: $RECOVERY"
echo "size:     $(( (${#CODE} - 2) / 2 )) bytes"
echo "keccak:   $(cast keccak "$CODE")"
echo "runtime:  $CODE"
