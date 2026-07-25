#!/usr/bin/env bash
# Deploy the leverage contracts to REAL Base mainnet. Spends REAL ETH. IRREVERSIBLE.
# Prereqs (see leverage-architecure.md §5 and §10):
#   - contracts audited (they are NOT yet — they custody leveraged user funds)
#   - Position impl + factory addresses registered with Bebop, or quotes get rejected
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a
: "${BASE_RPC:?set BASE_RPC in .env to a real Base mainnet RPC}"
: "${DEPLOYER_KEY:?set DEPLOYER_KEY in .env (a funded Base mainnet account)}"

# Refuse to deploy against the local fork by mistake.
case "$BASE_RPC" in
  *127.0.0.1*|*localhost*) echo "✗ BASE_RPC points at localhost — that's the fork, not mainnet."; exit 1 ;;
esac

# Confirm the RPC really is Base mainnet.
CID=$(cast chain-id --rpc-url "$BASE_RPC")
[ "$CID" = "8453" ] || { echo "✗ RPC chain id is $CID, expected 8453 (Base mainnet)."; exit 1; }

DEPLOYER=$(cast wallet address --private-key "$DEPLOYER_KEY")
BAL=$(cast balance "$DEPLOYER" --rpc-url "$BASE_RPC")
echo "Network : Base mainnet (8453) via $BASE_RPC"
echo "Deployer: $DEPLOYER"
echo "Balance : $(cast from-wei "$BAL") ETH"

# Refuse on an unfunded deployer — otherwise the script writes addresses.json from a
# simulation while nothing actually deploys (silent failure: app calls a factory that
# doesn't exist). ~0.0005 ETH comfortably covers the deploy.
python3 -c "import sys; sys.exit(0 if int('$BAL') >= 5*10**14 else 1)" || {
  echo "✗ deployer has too little ETH to deploy. Fund $DEPLOYER with ~0.001 ETH on Base first."; exit 1;
}

echo
echo "This deploys Position + PositionFactory to REAL Base and spends REAL ETH. Irreversible."
read -r -p "Type DEPLOY to proceed: " ans
[ "$ans" = "DEPLOY" ] || { echo "aborted."; exit 1; }

( cd contracts && forge script script/Deploy.s.sol --rpc-url "$BASE_RPC" --broadcast --private-key "$DEPLOYER_KEY" )

# Verify the broadcast actually landed (not just a simulation).
FACTORY=$(python3 -c "import json;print(json.load(open('contracts/addresses.json'))['factory'])")
[ "$(cast code "$FACTORY" --rpc-url "$BASE_RPC")" != "0x" ] || {
  echo "✗ broadcast did not land — factory $FACTORY has no code on-chain. Check the forge output above."; exit 1;
}

# Persist to the fork-proof live file. addresses.json is rewritten by every `npm run dev`
# (fork deploy at the same chainId 8453); serve:live reads addresses.live.json instead.
cp contracts/addresses.json contracts/addresses.live.json
echo
echo "▸ deployed and verified on-chain: factory $FACTORY"
echo "▸ wrote contracts/addresses.live.json (immune to fork overwrites)"
echo "▸ NEXT: register that factory + impl with Bebop, then start the live UI:  npm run serve:live"
