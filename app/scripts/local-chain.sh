#!/usr/bin/env bash
# Local rehearsal of the testnet deployment: anvil, then DeployTestnet, which deploys, wires and seeds everything.
# The protocol reads no external feed, so nothing is mocked. Writes app/src/config/deployments/31337.json;
# start the app with VITE_CHAIN_ID=31337. Requires Foundry. Run from anywhere: ./app/scripts/local-chain.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RPC="${RPC:-http://127.0.0.1:8545}"
# anvil's first default account, public test key
KEY="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"

cd "$ROOT"

if ! cast chain-id --rpc-url "$RPC" >/dev/null 2>&1; then
  # On the port RPC names, so a local chain on another port does not start a node on anvil's default one.
  PORT="${RPC##*:}"
  PORT="${PORT%%/*}"
  echo "Starting anvil on $RPC"
  anvil --silent --chain-id 31337 --port "$PORT" &
  for _ in $(seq 1 50); do cast chain-id --rpc-url "$RPC" >/dev/null 2>&1 && break; sleep 0.2; done
fi

forge script script/testnet/DeployTestnet.s.sol --rpc-url "$RPC" --private-key "$KEY" --broadcast -q
echo "Wrote app/src/config/deployments/31337.json"
