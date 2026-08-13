#!/usr/bin/env bash
# =============================================================================
# Phase 7c.2 — Fix payroll payout "API parameter invalid" (native USDC tokenId)
# =============================================================================
#
# ROOT CAUSE (confirmed against @circle-fin/developer-controlled-wallets@10.8.0
# type defs):
#
#   createTransaction's token identity is a STRICT union:
#     TokenIdInput                  -> { tokenId }                (tokenAddress: never)
#     TokenAddressAndBlockchainInput-> { tokenAddress, blockchain}(tokenId: never)
#   The SDK doc on tokenAddress says verbatim: "Empty for native tokens."
#
#   On Arc, USDC IS the native gas token => it has NO tokenAddress. The old
#   fallback sent tokenAddress:'0x3600...0000' (a placeholder, not a real
#   ERC-20). Circle rejects a native transfer carrying a bogus tokenAddress =>
#   "API parameter invalid", for EVERY recipient.
#
#   Why the fallback ran at all: resolveUsdcTokenId() scanned the balance list
#   and could return null (native entries, or a pre-funding call), and it
#   POISON-CACHED that null at module scope for the life of the process.
#
# FIX:
#   1. platformDisbursement.ts
#      - resolveUsdcTokenId(): match native/USDC by isNative||symbol, return
#        token.id, and NEVER cache a null (only cache a real id).
#      - sendUsdc(): if no tokenId resolves, THROW a clear error instead of
#        sending the invalid tokenAddress fallback (no more misleading msg).
#      - getPayoutStatus already returns txHash; unchanged.
#   2. payroll.ts
#      - add temporary GET /payroll/disbursement/tokens diagnostic so we can
#        see exactly what Circle reports (id/symbol/isNative/amount) for the
#        funded wallet and confirm a real tokenId resolves BEFORE re-running.
#
# SAFE TO RE-RUN: each edit checks for its own marker and skips if present.
# TEST LOCALLY (npm run build + hit /disbursement/tokens) BEFORE pushing.
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
API="$ROOT/afrifx-api"
DISB="$API/src/services/platformDisbursement.ts"
PAYROLL="$API/src/routes/payroll.ts"

[ -f "$DISB" ]    || { echo "ERR: $DISB not found (run from repo root)"; exit 1; }
[ -f "$PAYROLL" ] || { echo "ERR: $PAYROLL not found (run from repo root)"; exit 1; }

echo "==> Phase 7c.2: fixing native-USDC tokenId resolution"

# ----------------------------------------------------------------------------
# 1) Rewrite resolveUsdcTokenId() in platformDisbursement.ts
# ----------------------------------------------------------------------------
python3 - "$DISB" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()

if 'PHASE_7C2' in s:
    print("   platformDisbursement.ts already patched (PHASE_7C2 marker) - skipping")
    sys.exit(0)

# --- replace the resolveUsdcTokenId block ---------------------------------
old_resolve_start = "let _usdcTokenId: string | null = null"
idx = s.find(old_resolve_start)
if idx == -1:
    sys.exit("ERR: could not find resolveUsdcTokenId anchor")
# end of the function is the closing brace before the next `/** The on-chain`
end_anchor = "/** The on-chain address of the disbursement wallet"
end = s.find(end_anchor, idx)
if end == -1:
    sys.exit("ERR: could not find end anchor after resolveUsdcTokenId")

new_resolve = '''// PHASE_7C2: resolve the Circle tokenId for USDC on this wallet's chain.
//
// On Arc, USDC is the NATIVE token (isNative:true, no tokenAddress). Circle's
// transfer API takes EITHER { tokenId } OR { tokenAddress, blockchain } and
// rejects a native transfer that carries a tokenAddress. So we must send
// tokenId. We read it from the wallet's token balances, matching a USDC or
// native entry, and return its token.id.
//
// Cache ONLY a real id - never cache null (a pre-funding/empty read must not
// poison every later payout in this process).
let _usdcTokenId: string | null = null
async function resolveUsdcTokenId(walletId: string): Promise<string | null> {
  if (_usdcTokenId) return _usdcTokenId
  const c = client()
  const res = await c.getWalletTokenBalance({ id: walletId })
  const balances = res.data?.tokenBalances ?? []

  const match = balances.find(b => {
    const t = b.token ?? {}
    const sym  = String((t as any).symbol ?? '').toUpperCase()
    const addr = String((t as any).tokenAddress ?? '').toLowerCase()
    const native = (t as any).isNative === true
    // On Arc the native token IS USDC; elsewhere match the USDC symbol/address.
    return sym === 'USDC' || native || addr === USDC_ADDRESS.toLowerCase()
  })

  const id = (match?.token as any)?.id ? String((match!.token as any).id) : null
  if (id) _usdcTokenId = id   // cache real ids only
  return id
}

/**
 * Diagnostic: list the raw token balances Circle reports for a wallet.
 * Used by GET /payroll/disbursement/tokens to confirm a real USDC tokenId
 * resolves before re-running a batch. Never logs secrets.
 */
export async function listWalletTokens(walletId: string): Promise<Array<{
  id: string | null; symbol: string | null; isNative: boolean;
  tokenAddress: string | null; amount: string | null
}>> {
  const c = client()
  const res = await c.getWalletTokenBalance({ id: walletId })
  return (res.data?.tokenBalances ?? []).map(b => {
    const t = (b.token ?? {}) as any
    return {
      id:           t.id ? String(t.id) : null,
      symbol:       t.symbol ?? null,
      isNative:     t.isNative === true,
      tokenAddress: t.tokenAddress ?? null,
      amount:       b.amount ?? null,
    }
  })
}

'''

s = s[:idx] + new_resolve + s[end:]

# --- fix sendUsdc: fail loudly instead of sending the bad address fallback --
old_ident = '''  // Prefer tokenId (works for native USDC like Arc's). Fall back to
  // tokenAddress+blockchain if the id can't be resolved.
  const tokenId = await resolveUsdcTokenId(params.walletId).catch(() => null)
  const tokenIdent = tokenId
    ? { tokenId }
    : { tokenAddress: USDC_ADDRESS, blockchain: BLOCKCHAIN as any }'''

new_ident = '''  // PHASE_7C2: USDC on Arc is native => it has NO tokenAddress. Circle rejects
  // a native transfer that carries a tokenAddress ("API parameter invalid"), so
  // we MUST send tokenId. If we can't resolve one, fail with a clear message
  // rather than sending an invalid body.
  const tokenId = await resolveUsdcTokenId(params.walletId).catch(() => null)
  if (!tokenId) {
    throw new Error(
      'Could not resolve a Circle USDC tokenId for the disbursement wallet. ' +
      'Confirm the float is funded and visible via GET /payroll/disbursement/tokens.')
  }
  const tokenIdent = { tokenId }'''

if old_ident not in s:
    sys.exit("ERR: sendUsdc tokenIdent block not found (did the file change?)")
s = s.replace(old_ident, new_ident)

open(p, 'w', encoding='utf-8').write(s)
print("   platformDisbursement.ts patched")
PY

# ----------------------------------------------------------------------------
# 2) Add GET /payroll/disbursement/tokens diagnostic route
# ----------------------------------------------------------------------------
python3 - "$PAYROLL" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()

if 'disbursement/tokens' in s:
    print("   payroll.ts already has /disbursement/tokens - skipping")
    sys.exit(0)

anchor = "export default router"
if anchor not in s:
    sys.exit("ERR: could not find 'export default router' in payroll.ts")

route = '''// GET /payroll/disbursement/tokens   (PHASE_7C2 diagnostic)
//
// Show exactly what Circle reports for the funded disbursement wallet:
// each token's id, symbol, isNative flag, address and amount. Use this to
// confirm a real USDC tokenId resolves before re-running a batch. Safe to
// remove once payouts are green.
router.get('/disbursement/tokens', async (_req, res) => {
  const walletId = process.env.PAYROLL_DISBURSEMENT_WALLET_ID
  if (!walletId) return res.status(400).json({ error: 'Disbursement wallet not configured' })
  try {
    const { listWalletTokens } = await import('../services/platformDisbursement')
    const tokens = await listWalletTokens(walletId)
    res.json({ walletId, tokens })
  } catch (err: any) {
    res.status(502).json({ error: err.message })
  }
})

'''

s = s.replace(anchor, route + anchor)
open(p, 'w', encoding='utf-8').write(s)
print("   payroll.ts patched (added GET /disbursement/tokens)")
PY

# ----------------------------------------------------------------------------
# 3) Type-check
# ----------------------------------------------------------------------------
echo "==> Type-checking afrifx-api"
cd "$API"
if [ -f node_modules/.bin/tsc ]; then
  npx tsc --noEmit && echo "   tsc: OK"
else
  echo "   (node_modules not installed here; run 'npm run build' locally before pushing)"
fi

cat <<'NEXT'

==> Phase 7c.2 applied.

VERIFY LOCALLY BEFORE PUSHING:
  1. cd afrifx-api && npm run build          # must compile clean
  2. Start the API, then:
       curl -s localhost:PORT/payroll/disbursement/tokens | jq
     Expect a USDC entry with a non-null "id" and (on Arc) "isNative": true.
     -> That "id" is the tokenId sendUsdc will now use.
  3. Re-execute a small test batch:
       POST /payroll/batches/:id/execute
     Recipients should go paid; if any fail, the red ERR: string is now the
     REAL Circle reason (no longer masked by the invalid-address fallback).

IF /disbursement/tokens shows USDC with a null id:
  the wallet-balance endpoint isn't exposing token.id for the native asset on
  your account; tell me the JSON it returns and I'll switch resolution to the
  token-list lookup (getToken / listTransactions) in a 7c.3.

NOTE (separate, non-blocking): in payroll.ts runBatchPayout marks a recipient
'paid' using result.txHash, but sendUsdc returns only { id, state } (txHash
arrives later via getPayoutStatus). Paid rows currently store the tx id, not
the hash. Say the word and I'll fold a poll-for-hash step into 7c.3.
NEXT
