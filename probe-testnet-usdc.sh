#!/usr/bin/env bash
# ============================================================
# probe-testnet-usdc.sh
# Proves the USDC balance-read path for ALL FOUR non-Arc testnet chains
# side by side, so we can see which reads succeed and which throw.
#
# For each chain it checks, over the SAME public RPC the app uses:
#   1. RPC reachable? (eth_chainId, expected value shown)
#   2. Contract has bytecode at the configured USDC address?
#   3. symbol() and decimals()
#   4. balanceOf(YOUR_ADDR)
#
# No keys, no deps beyond node's global fetch. Writes a temp .mjs, runs it,
# deletes it. Override any RPC with the matching NEXT_PUBLIC_*_RPC_URL env var.
# ============================================================
set -euo pipefail

ADDR="${1:-0x742682e7b30f7bfc46f8718fffeadf9f926562d9}"

TMP="$(mktemp --suffix=.mjs)"
cat > "$TMP" <<'JS'
const ADDR = process.env.__ADDR;

// (name, expectedChainId, rpc, usdc) — addresses/RPCs mirror cctp-chains.ts
const CHAINS = [
  ["Base Sepolia",     84532,    process.env.NEXT_PUBLIC_BASE_RPC_URL    || "https://sepolia.base.org",                     "0x036CbD53842c5426634e7929541eC2318f3dCF7e"],
  ["Ethereum Sepolia", 11155111, process.env.NEXT_PUBLIC_ETH_RPC_URL     || "https://rpc.sepolia.org",                      "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238"],
  ["Arbitrum Sepolia", 421614,   process.env.NEXT_PUBLIC_ARB_RPC_URL     || "https://sepolia-rollup.arbitrum.io/rpc",       "0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d"],
  ["Polygon Amoy",     80002,    process.env.NEXT_PUBLIC_POLYGON_RPC_URL || "https://rpc-amoy.polygon.technology",          "0x41E94Eb019C0762f9Bfcf9Fb1E58725BfB0e7582"],
];

const pad = (h) => h.replace(/^0x/, "").padStart(64, "0");

async function rpc(url, method, params) {
  const r = await fetch(url, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
  });
  const j = await r.json();
  if (j.error) throw new Error(method + " -> " + JSON.stringify(j.error));
  return j.result;
}
const ethCall = (url, to, data) => rpc(url, "eth_call", [{ to, data }, "latest"]);

function decodeString(hex) {
  hex = hex.replace(/^0x/, "");
  const len = parseInt(hex.slice(64, 128), 16);
  return Buffer.from(hex.slice(128, 128 + len * 2), "hex").toString("utf8");
}

console.log("Reading USDC balance for:", ADDR, "\n");

for (const [name, expCid, url, usdc] of CHAINS) {
  console.log("── " + name + " ──");
  console.log("   RPC:", url);
  console.log("   USDC:", usdc);
  try {
    const cid = parseInt(await rpc(url, "eth_chainId", []), 16);
    console.log("   chainId:", cid, cid === expCid ? "OK" : "MISMATCH! expected " + expCid);
  } catch (e) { console.log("   RPC UNREACHABLE:", e.message, "\n"); continue; }

  try {
    const code = await rpc(url, "eth_getCode", [usdc, "latest"]);
    const hasCode = code && code !== "0x";
    console.log("   bytecode:", hasCode ? "YES (" + ((code.length - 2) / 2) + " bytes)" : "NONE — no contract at this address!");
    if (!hasCode) { console.log(""); continue; }
  } catch (e) { console.log("   getCode FAIL:", e.message); }

  try {
    const dec = parseInt(await ethCall(url, usdc, "0x313ce567"), 16);
    let sym = "?";
    try { sym = decodeString(await ethCall(url, usdc, "0x95d89b41")); } catch {}
    console.log("   symbol:", JSON.stringify(sym), " decimals:", dec);
    const bal = BigInt(await ethCall(url, usdc, "0x70a08231" + pad(ADDR)));
    console.log("   balanceOf RAW:", bal.toString());
    console.log("   balanceOf /1e" + dec + ":", Number(bal) / 10 ** dec);
  } catch (e) { console.log("   TOKEN READ FAIL:", e.message); }
  console.log("");
}
JS

__ADDR="$ADDR" node "$TMP"
rm -f "$TMP"
echo "Done."
