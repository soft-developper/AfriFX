#!/usr/bin/env bash
# ============================================================
# fix-amoy-sepolia-rpc.sh
# Root cause (proven via probes): the default public RPCs for Polygon Amoy
# (rpc-amoy.polygon.technology) and Ethereum Sepolia (rpc.sepolia.org) are
# unreachable/broken, so balanceOf throws. useChainUsdcBalance swallowed the
# error and showed 0 — making real balances (Amoy 5 USDC, Sepolia 49 USDC)
# look empty and forcing "Max" to 0.
#
# This does two things:
#   1. Swap the broken default RPCs for proven publicnode endpoints
#      (no API key; consistent with the chains that already work).
#      Overridable via NEXT_PUBLIC_POLYGON_RPC_URL / NEXT_PUBLIC_ETH_RPC_URL.
#   2. Stop useChainUsdcBalance from masking RPC failures as a fake "0":
#      keep the last known balance and expose an `error` flag instead.
#
# Idempotent: safe to re-run. Run from repo root: cd ~/AfriFX && bash fix-amoy-sepolia-rpc.sh
# ============================================================
set -euo pipefail

ROOT="$(pwd)"
WEB="$ROOT/afrifx-web"
[ -d "$WEB" ] || { echo "ERROR: run from the AfriFX repo root (afrifx-web/ not found here: $ROOT)"; exit 1; }

BC="$WEB/lib/bridge-chains.ts"
CC="$WEB/lib/cctp-chains.ts"
HOOK="$WEB/hooks/useChainUsdcBalance.ts"
for f in "$BC" "$CC" "$HOOK"; do [ -f "$f" ] || { echo "ERROR: missing $f"; exit 1; }; done

AMOY_GOOD="https://polygon-amoy-bor-rpc.publicnode.com"
SEP_GOOD="https://ethereum-sepolia-rpc.publicnode.com"

echo "→ Patching RPC defaults…"

# 1a. bridge-chains.ts — Amoy default (line ~64)
if grep -q "NEXT_PUBLIC_POLYGON_RPC_URL ?? 'https://rpc-amoy.polygon.technology'" "$BC"; then
  perl -0pi -e "s{(\[polygonAmoy\.id\]:\s*process\.env\.NEXT_PUBLIC_POLYGON_RPC_URL \?\? ')https://rpc-amoy\.polygon\.technology(')}{\${1}${AMOY_GOOD}\${2}}g" "$BC"
  echo "  ✓ bridge-chains.ts: Amoy RPC → publicnode"
else
  echo "  • bridge-chains.ts: Amoy already patched (skip)"
fi

# 1b. cctp-chains.ts — Sepolia rpcUrl (line ~107)
if grep -q "NEXT_PUBLIC_ETH_RPC_URL ?? 'https://rpc.sepolia.org'" "$CC"; then
  perl -0pi -e "s{(NEXT_PUBLIC_ETH_RPC_URL \?\? ')https://rpc\.sepolia\.org(')}{\${1}${SEP_GOOD}\${2}}g" "$CC"
  echo "  ✓ cctp-chains.ts: Sepolia RPC → publicnode"
else
  echo "  • cctp-chains.ts: Sepolia already patched (skip)"
fi

# 1c. cctp-chains.ts — Amoy rpcUrl (line ~119)
if grep -q "NEXT_PUBLIC_POLYGON_RPC_URL ?? 'https://rpc-amoy.polygon.technology'" "$CC"; then
  perl -0pi -e "s{(NEXT_PUBLIC_POLYGON_RPC_URL \?\? ')https://rpc-amoy\.polygon\.technology(')}{\${1}${AMOY_GOOD}\${2}}g" "$CC"
  echo "  ✓ cctp-chains.ts: Amoy RPC → publicnode"
else
  echo "  • cctp-chains.ts: Amoy already patched (skip)"
fi

echo
echo "→ Patching useChainUsdcBalance to stop masking RPC failures as 0…"

if grep -q "// A failed read shouldn't break the form; just show zero" "$HOOK"; then
  # Rewrite the hook to keep last-known balance and expose an error flag.
  cat > "$HOOK" <<'TS'
'use client'
// ============================================================
// useChainUsdcBalance — read a wallet's USDC balance on ANY supported chain.
//
// The app's existing useUSDCBalance is pinned to Arc, which is right for Send's
// same-chain path but useless for the bridge, where the source chain changes.
// This reads balanceOf on whichever chain is selected.
//
// NOTE: a failed RPC read no longer silently shows 0. A dead/rate-limited RPC
// used to be indistinguishable from a genuinely empty wallet — that masked the
// real Amoy/Sepolia balances behind a fake "0" and set Max to 0. We now keep
// the last known balance and expose `error` so the UI can tell the difference.
// ============================================================

import { useState, useEffect, useCallback, useRef } from 'react'
import { useConfig } from 'wagmi'
import { getPublicClient } from 'wagmi/actions'
import { useAccountAddress as useAccount } from '@/hooks/useAccountAddress'
import { chainByKey } from '@/lib/cctp-chains'
import { evmChainId } from '@/lib/bridge-chains'

const ERC20_BALANCE_ABI = [
  {
    type: 'function', name: 'balanceOf', stateMutability: 'view',
    inputs: [{ name: 'account', type: 'address' }],
    outputs: [{ name: '', type: 'uint256' }],
  },
] as const

export function useChainUsdcBalance(chainKey: string) {
  const { address } = useAccount()
  const config = useConfig()
  const [balance, setBalance] = useState<number>(0)
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)
  // Track which (address, chain) the current balance belongs to, so a switch
  // resets to 0 rather than showing a stale balance from the previous chain.
  const scopeRef = useRef<string>('')

  const load = useCallback(async () => {
    const scope = `${address ?? ''}:${chainKey}`
    if (!address) { scopeRef.current = scope; setBalance(0); setError(null); return }
    const chain   = chainByKey(chainKey)
    const chainId = evmChainId(chainKey)
    if (!chain?.usdc || !chainId) {
      scopeRef.current = scope; setBalance(0)
      setError('Chain not configured'); return
    }

    // New scope (address or chain changed): clear stale balance first.
    if (scopeRef.current !== scope) { setBalance(0); scopeRef.current = scope }

    setLoading(true)
    setError(null)
    try {
      const client = getPublicClient(config, { chainId })
      if (!client) { setError('No RPC client for this chain'); return }
      const raw = await client.readContract({
        address: chain.usdc as `0x${string}`,
        abi: ERC20_BALANCE_ABI,
        functionName: 'balanceOf',
        args: [address],
      })
      // USDC is 6 decimals on every supported chain, including Arc's ERC-20
      // interface (the NATIVE token is 18 — mixing them is a known trap).
      setBalance(Number(raw as bigint) / 1_000_000)
      setError(null)
    } catch (e) {
      // Do NOT fake a 0 here — that hid real balances behind dead RPCs. Surface
      // the failure and keep whatever balance we last had for this scope.
      const msg = e instanceof Error ? e.message : 'Balance read failed'
      setError(msg)
    } finally {
      setLoading(false)
    }
  }, [address, chainKey, config])

  useEffect(() => { load() }, [load])

  return { balance, loading, error, refresh: load }
}
TS
  echo "  ✓ useChainUsdcBalance.ts: rewritten (last-known balance + error flag)"
else
  echo "  • useChainUsdcBalance.ts: already patched (skip)"
fi

echo
echo "→ Verifying no broken RPC strings remain in defaults:"
if grep -rnE "rpc-amoy\.polygon\.technology|'https://rpc\.sepolia\.org'" "$BC" "$CC"; then
  echo "  ⚠ Found leftover references above — review manually."
else
  echo "  ✓ No broken default RPCs remain."
fi

echo
echo "→ Changed lines:"
grep -nE "publicnode\.com" "$BC" "$CC" || true

echo
echo "Done. Next:"
echo "  cd afrifx-web && rm -rf .next && npx tsc --noEmit && npm run build && cd .."
echo "  (test the bridge Amoy/Sepolia balance locally, then commit + push)"
