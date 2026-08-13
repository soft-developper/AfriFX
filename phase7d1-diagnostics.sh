#!/usr/bin/env bash
# =============================================================================
# Phase 7d.1 — DIAGNOSTIC ONLY (no fix): reveal why Circle rejects the transfer
# =============================================================================
#
# WHERE WE ARE:
#   Three attempts, identical rejection: "API parameter invalid" + empty
#   errors[]. That constancy is the clue - the failing parameter did NOT change
#   across native tokenId (7c.2), ERC-20 tokenId (7c.3), or account type (7d).
#   Empty errors[] = Circle rejects the request SHAPE before field validation.
#
#   I've theorized the cause three times and been wrong. Stop guessing. This
#   script adds VISIBILITY, changes NO behavior, and one run tells us the truth:
#
#   1. GET /payroll/disbursement/wallet-info -> the wallet's REAL accountType
#      straight from Circle (getWallet). Answers: is 00093b1a... actually EOA,
#      or did the re-provision run on pre-7d code and it's still SCA?
#
#   2. [sendUsdc] request body log: prints the EXACT object passed to
#      createTransaction (walletId, token identity, amount array, fee, refId)
#      right before the call. Answers: is amount malformed? is tokenIdent the
#      shape we think? We compare it field-by-field to Circle's working Arc
#      transfer example.
#
# NOTHING ELSE CHANGES. After we read the output we write the real fix.
#
# SAFE TO RE-RUN: idempotent via PHASE_7D1 marker.
# TEST LOCALLY (npm run build) BEFORE pushing.
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
API="$ROOT/afrifx-api"
DISB="$API/src/services/platformDisbursement.ts"
PAYROLL="$API/src/routes/payroll.ts"

[ -f "$DISB" ]    || { echo "ERR: $DISB not found (run from repo root)"; exit 1; }
[ -f "$PAYROLL" ] || { echo "ERR: $PAYROLL not found (run from repo root)"; exit 1; }

echo "==> Phase 7d.1: diagnostics (accountType read + request-body log)"

# ----------------------------------------------------------------------------
# 1) Add getDisbursementWalletInfo() + log the exact createTransaction body
# ----------------------------------------------------------------------------
python3 - "$DISB" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()

if 'PHASE_7D1' in s:
    print("   platformDisbursement.ts already patched (PHASE_7D1) - skipping")
    sys.exit(0)

# a) new export: read the wallet's real accountType from Circle.
anchor = "export interface PayoutResult {"
if anchor not in s:
    sys.exit("ERR: PayoutResult anchor not found")
info_fn = '''// PHASE_7D1 (diagnostic): read the wallet's REAL account type from Circle.
// getWallet returns accountType ('EOA' | 'SCA') and, for SCAs, scaCore. This
// is the only authoritative way to confirm what was actually provisioned.
export async function getDisbursementWalletInfo(walletId: string): Promise<{
  id: string; address: string | null; blockchain: string | null;
  accountType: string | null; scaCore: string | null; state: string | null
}> {
  const c = client()
  const res = await c.getWallet({ id: walletId })
  const w = (res.data?.wallet ?? {}) as any
  return {
    id:          String(w.id ?? walletId),
    address:     w.address ?? null,
    blockchain:  w.blockchain ?? null,
    accountType: w.accountType ?? null,
    scaCore:     w.scaCore ?? null,
    state:       w.state ?? null,
  }
}

'''
s = s.replace(anchor, info_fn + anchor)

# b) log the exact body right before createTransaction.
#    Handle whichever tokenIdent form is currently in the file (7c.2 or 7c.3).
call_anchor = "  let res\n  try {\n    res = await c.createTransaction({"
if call_anchor not in s:
    sys.exit("ERR: createTransaction call anchor not found")

log_block = '''  // PHASE_7D1 (diagnostic): print the EXACT body we send Circle, so an
  // "API parameter invalid" with empty errors[] can be read field-by-field.
  const _debugBody = {
    walletId:           params.walletId,
    tokenIdent,
    destinationAddress: params.destinationAddress,
    amount:             [params.amount.toString()],
    amountRaw:          params.amount,
    amountType:         typeof params.amount,
    fee:                { type: 'level', config: { feeLevel: 'MEDIUM' } },
    refId:              params.refId ?? null,
  }
  console.log('[sendUsdc] createTransaction body:', JSON.stringify(_debugBody))

  let res
  try {
    res = await c.createTransaction({'''
s = s.replace(call_anchor, log_block)

# mark
s = s.replace('export interface PayoutResult {',
              '/* PHASE_7D1 diagnostics active */\nexport interface PayoutResult {', 1)

open(p, 'w', encoding='utf-8').write(s)
print("   platformDisbursement.ts patched (wallet-info export + body log)")
PY

# ----------------------------------------------------------------------------
# 2) Add GET /payroll/disbursement/wallet-info route
# ----------------------------------------------------------------------------
python3 - "$PAYROLL" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()

if 'disbursement/wallet-info' in s:
    print("   payroll.ts already has /disbursement/wallet-info - skipping")
    sys.exit(0)

anchor = "export default router"
if anchor not in s:
    sys.exit("ERR: 'export default router' not found in payroll.ts")

route = '''// GET /payroll/disbursement/wallet-info   (PHASE_7D1 diagnostic)
//
// The wallet's REAL account type straight from Circle - the authoritative
// check that the re-provisioned wallet is actually EOA (not still SCA). Safe
// to remove once payouts are green.
router.get('/disbursement/wallet-info', async (_req, res) => {
  const walletId = process.env.PAYROLL_DISBURSEMENT_WALLET_ID
  if (!walletId) return res.status(400).json({ error: 'Disbursement wallet not configured' })
  try {
    const { getDisbursementWalletInfo } = await import('../services/platformDisbursement')
    const info = await getDisbursementWalletInfo(walletId)
    res.json(info)
  } catch (err: any) {
    res.status(502).json({ error: err.message })
  }
})

'''
s = s.replace(anchor, route + anchor)
open(p, 'w', encoding='utf-8').write(s)
print("   payroll.ts patched (added GET /disbursement/wallet-info)")
PY

echo "==> Type-checking afrifx-api"
cd "$API"
if [ -f node_modules/.bin/tsc ]; then
  npx tsc --noEmit && echo "   tsc: OK"
else
  echo "   (node_modules not installed here; run 'npm run build' locally before pushing)"
fi

cat <<'NEXT'

==> Phase 7d.1 applied (diagnostics only - no behavior change).

AFTER DEPLOY, RUN THESE TWO AND PASTE BOTH:

  1. The wallet's real account type:
       curl -s https://afrifx-api.onrender.com/payroll/disbursement/wallet-info | jq
     -> if "accountType" is "SCA": the re-provision ran on pre-7d code; the fix
        is simply to re-provision again now that 7d (EOA) is deployed.
     -> if "accountType" is "EOA": account type is NOT the cause, and...

  2. Re-run the test batch, then grab the body log from Render:
       [sendUsdc] createTransaction body: {...}
     Paste that line. It shows the exact amount/token/fee we send - we compare
     it to Circle's working Arc example and fix the real offending field.

One run of each ends the guessing. No fix ships until we've read them.
NEXT
