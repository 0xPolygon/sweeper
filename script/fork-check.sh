#!/usr/bin/env bash
# Usage: POLYGON_RPC_URL=<polygon rpc> script/fork-check.sh [fork-block]
# Installs the sweeper at each address on a local anvil fork and sweeps it.
set -euo pipefail

: "${POLYGON_RPC_URL:?set POLYGON_RPC_URL}"
FORK_BLOCK="${1:-}"
PORT="${PORT:-8549}"
RPC="http://127.0.0.1:$PORT"

RECOVERY_A=0x3dcE0a29139A851Da1dFCa56Af8e8a6440b4D952
RECOVERY_B=0x00000000000000000000000000000000B1Ace000
TARGETS=(
  "0xe4C4C39C1733e1C7c06B79f97ED442B68Df41EC6:$RECOVERY_A"
  "0x5392587814Ce8c6af6789764f88e5e9AB0b9962C:$RECOVERY_A"
  "0xc91ee0574a14446DE200923729c349B9CAE19b60:$RECOVERY_A"
  "0x3f7019221a925537DC20767C38e80A7127fb1Ffa:$RECOVERY_A"
  "0x5227f603C1eE34CE3C06eFe6477003BDfCCB2f8c:$RECOVERY_B"
)
USDT0=0xc2132D05D31c914a87C6611C10748AEb04B58e8F

cd "$(dirname "$0")/.."
forge build --quiet

ARGS=(--fork-url "$POLYGON_RPC_URL" --port "$PORT" --silent --no-rate-limit)
[ -n "$FORK_BLOCK" ] && ARGS+=(--fork-block-number "$FORK_BLOCK")
anvil "${ARGS[@]}" &
ANVIL_PID=$!
trap 'kill "$ANVIL_PID" 2>/dev/null || true' EXIT
for _ in $(seq 100); do cast chain-id --rpc-url "$RPC" >/dev/null 2>&1 && break; sleep 0.2; done
echo "fork block: $(cast block-number --rpc-url "$RPC")"

FROM="$(cast rpc --rpc-url "$RPC" eth_accounts | tr -d '[]" ' | cut -d, -f1)"

runtime_for() {
  local addr
  addr="$(forge create src/Sweeper.sol:Sweeper --rpc-url "$RPC" --unlocked --from "$FROM" --broadcast --json \
    --constructor-args "$1" 2>/dev/null | jq -r .deployedTo)"
  cast code "$addr" --rpc-url "$RPC"
}

echo
echo "== sweep each address with a normal tx =="
for entry in "${TARGETS[@]}"; do
  A="${entry%%:*}"; R="${entry##*:}"
  BAL="$(cast balance "$A" --rpc-url "$RPC")"; NONCE="$(cast nonce "$A" --rpc-url "$RPC")"
  RB="$(cast balance "$R" --rpc-url "$RPC")"
  USDT_BEFORE="$(cast call $USDT0 "balanceOf(address)(uint256)" "$A" --rpc-url "$RPC" | cut -d' ' -f1)"
  cast rpc --rpc-url "$RPC" anvil_setCode "$A" "$(runtime_for "$R")" >/dev/null
  [ "$(cast balance "$A" --rpc-url "$RPC")" = "$BAL" ] && [ "$(cast nonce "$A" --rpc-url "$RPC")" = "$NONCE" ] \
    || { echo "setCode changed balance/nonce at $A" >&2; exit 1; }
  GAS="$(cast send "$A" "sweep()" --rpc-url "$RPC" --unlocked --from "$FROM" --json | jq -r .gasUsed)"
  AFTER="$(cast balance "$A" --rpc-url "$RPC")"
  RA="$(cast balance "$R" --rpc-url "$RPC")"
  USDT_AFTER="$(cast call $USDT0 "balanceOf(address)(uint256)" "$A" --rpc-url "$RPC" | cut -d' ' -f1)"
  DELTA="$(python3 -c "print($RA - $RB)")"
  OK=$([ "$DELTA" = "$BAL" ] && [ "$AFTER" = 0 ] && [ "$USDT_BEFORE" = "$USDT_AFTER" ] && echo ok || echo MISMATCH)
  echo "$A before=$(cast from-wei "$BAL") after=$(cast from-wei "$AFTER") recovery+=$(cast from-wei "$DELTA") usdt0=$USDT_AFTER gasUsed=$(cast to-dec "$GAS") $OK"
done

echo
echo "== txs from an address that has the sweeper code =="
KEYJSON="$(cast wallet new --json)"
PK="$(jq -r '.data[0].private_key' <<<"$KEYJSON")"
CODED="$(jq -r '.data[0].address' <<<"$KEYJSON")"
cast rpc --rpc-url "$RPC" anvil_setBalance "$CODED" 0x56BC75E2D63100000 >/dev/null # 100 POL
cast rpc --rpc-url "$RPC" anvil_setCode "$CODED" "$(runtime_for "$RECOVERY_A")" >/dev/null
CODE_HASH="$(cast keccak "$(cast code "$CODED" --rpc-url "$RPC")")"

if OUT="$(cast send 0x000000000000000000000000000000000000dEaD --value 1ether --rpc-url "$RPC" --private-key "$PK" 2>&1)"; then
  echo "signed tx from an address with the sweeper code: accepted"
else
  echo "signed tx from an address with the sweeper code: rejected: $(grep -oiE 'sender not an eoa|eip-3607[^"]*|reject[^"]*' <<<"$OUT" | head -1)"
fi

A1="${TARGETS[0]%%:*}"
cast rpc --rpc-url "$RPC" anvil_impersonateAccount "$A1" >/dev/null
cast rpc --rpc-url "$RPC" anvil_setBalance "$A1" 0x56BC75E2D63100000 >/dev/null
if cast send 0x000000000000000000000000000000000000dEaD --value 1ether --rpc-url "$RPC" --unlocked --from "$A1" >/dev/null 2>&1; then
  echo "impersonated tx from $A1: accepted"
else
  echo "impersonated tx from $A1: rejected"
fi
cast rpc --rpc-url "$RPC" anvil_stopImpersonatingAccount "$A1" >/dev/null

echo
echo "== EIP-7702 authorization signed for an address with the sweeper code =="
IMPL="$(forge create test/Sweeper.t.sol:MockToken --rpc-url "$RPC" --unlocked --from "$FROM" --broadcast --json 2>/dev/null | jq -r .deployedTo)"
AUTH_NONCE="$(cast nonce "$CODED" --rpc-url "$RPC")"
CHAIN_ID="$(cast chain-id --rpc-url "$RPC")"
AUTH="$(cast wallet sign-auth "$IMPL" --private-key "$PK" --nonce "$AUTH_NONCE" --chain "$CHAIN_ID" 2>/dev/null)"
RELAYER_JSON="$(cast wallet new --json)"
RPK="$(jq -r '.data[0].private_key' <<<"$RELAYER_JSON")"
RADDR="$(jq -r '.data[0].address' <<<"$RELAYER_JSON")"
cast rpc --rpc-url "$RPC" anvil_setBalance "$RADDR" 0x56BC75E2D63100000 >/dev/null
if OUT="$(cast send 0x000000000000000000000000000000000000dEaD --auth "$AUTH" --rpc-url "$RPC" --private-key "$RPK" --json 2>/dev/null)"; then
  echo "type-4 tx carrying the authorization: mined"
else
  echo "type-4 tx carrying the authorization: rejected: $(head -c 200 <<<"$OUT")"
fi
if [ "$(cast keccak "$(cast code "$CODED" --rpc-url "$RPC")")" = "$CODE_HASH" ]; then
  echo "code after authorization: unchanged"
else
  echo "code after authorization: CHANGED to $(cast code "$CODED" --rpc-url "$RPC" | head -c 60)"
fi
unset PK RPK KEYJSON RELAYER_JSON
