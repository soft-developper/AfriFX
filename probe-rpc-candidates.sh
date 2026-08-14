#!/usr/bin/env bash
# Tests candidate PUBLIC RPCs for the two broken testnet chains
# (Polygon Amoy + Ethereum Sepolia). Prints which respond with a valid
# chainId AND can read your USDC balance. Pick the first that passes.
set -euo pipefail

ADDR="${1:-0x742682e7b30f7bfc46f8718fffeadf9f926562d9}"

TMP="$(mktemp --suffix=.mjs)"
cat > "$TMP" <<'JS'
const ADDR = process.env.__ADDR;
const pad = (h) => h.replace(/^0x/, "").padStart(64, "0");

const CANDIDATES = {
  "Polygon Amoy (chainId 80002, USDC 0x41E9...7582)": {
    cid: 80002,
    usdc: "0x41E94Eb019C0762f9Bfcf9Fb1E58725BfB0e7582",
    rpcs: [
      "https://rpc-amoy.polygon.technology",
      "https://polygon-amoy-bor-rpc.publicnode.com",
      "https://polygon-amoy.drpc.org",
      "https://rpc.ankr.com/polygon_amoy",
      "https://80002.rpc.thirdweb.com",
    ],
  },
  "Ethereum Sepolia (chainId 11155111, USDC 0x1c7D...7238)": {
    cid: 11155111,
    usdc: "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238",
    rpcs: [
      "https://rpc.sepolia.org",
      "https://ethereum-sepolia-rpc.publicnode.com",
      "https://sepolia.drpc.org",
      "https://rpc.ankr.com/eth_sepolia",
      "https://1rpc.io/sepolia",
    ],
  },
};

async function rpc(url, method, params, ms = 8000) {
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), ms);
  try {
    const r = await fetch(url, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
      signal: ctrl.signal,
    });
    const text = await r.text();
    let j;
    try { j = JSON.parse(text); } catch { throw new Error("non-JSON (HTTP " + r.status + ")"); }
    if (j.error) throw new Error(JSON.stringify(j.error));
    return j.result;
  } finally { clearTimeout(t); }
}

for (const [label, cfg] of Object.entries(CANDIDATES)) {
  console.log("\n=== " + label + " ===");
  for (const url of cfg.rpcs) {
    process.stdout.write("  " + url.padEnd(52) + " ");
    try {
      const cid = parseInt(await rpc(url, "eth_chainId", []), 16);
      if (cid !== cfg.cid) { console.log("BAD chainId " + cid); continue; }
      const data = "0x70a08231" + pad(ADDR);
      const bal = BigInt(await rpc(url, "eth_call", [{ to: cfg.usdc, data }, "latest"]));
      console.log("OK  balance=" + (Number(bal) / 1e6) + " USDC");
    } catch (e) { console.log("FAIL " + e.message); }
  }
}
JS

__ADDR="$ADDR" node "$TMP"
rm -f "$TMP"
echo; echo "Done. Pick the first OK endpoint for each chain."
