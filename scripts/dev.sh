#!/usr/bin/env bash
# One command: Anvil fork of Base -> deploy contracts -> backend + frontend.
# Fork state (faucet funds, positions, deployed contracts) PERSISTS across restarts
# via --state. For a clean slate: rm .anvil-state.json  (or: npm run dev:fresh).
# Ctrl-C tears everything down.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Upstream Base RPC to fork FROM (must allow archive storage reads for a pinned fork).
# publicnode now 403s archive requests; mainnet.base.org works. Override via BASE_RPC only
# if it's a real remote endpoint (not the local fork itself).
RPC="${BASE_RPC:-https://mainnet.base.org}"
case "$RPC" in http://127.0.0.1*|http://localhost*) RPC="https://mainnet.base.org" ;; esac
PORT=8545
STATE="$ROOT/.anvil-state.json"
KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80

cleanup() { kill $(jobs -p) 2>/dev/null || true; }
trap cleanup EXIT INT TERM

[ -d node_modules/viem ] || npm install
npm run build:web  # bundle viem for the browser (served locally, no CDN)

echo "▸ starting Anvil fork of Base (state: ${STATE##*/})…"
# --state loads the file if it exists and dumps back to it on exit → funds survive restarts
anvil --fork-url "$RPC" --port "$PORT" --state "$STATE" --silent &
until cast chain-id --rpc-url "http://localhost:$PORT" >/dev/null 2>&1; do sleep 0.5; done

# Redeploy only if the contracts aren't already on the (persisted) fork.
NEED_DEPLOY=1
if [ -f contracts/addresses.json ]; then
  FACTORY=$(python3 -c "import json;print(json.load(open('contracts/addresses.json'))['factory'])" 2>/dev/null || true)
  if [ -n "${FACTORY:-}" ]; then
    CODE=$(cast code "$FACTORY" --rpc-url "http://localhost:$PORT" 2>/dev/null || echo 0x)
    [ "$CODE" != "0x" ] && [ -n "$CODE" ] && NEED_DEPLOY=0
  fi
fi

if [ "$NEED_DEPLOY" = "1" ]; then
  echo "▸ deploying contracts…"
  ( cd contracts && forge script script/Deploy.s.sol \
      --rpc-url "http://localhost:$PORT" --broadcast --private-key "$KEY" >/dev/null )
else
  echo "▸ reusing persisted contracts at $FACTORY"
fi

echo "▸ frontend + backend → http://localhost:3000"
node server.ts
