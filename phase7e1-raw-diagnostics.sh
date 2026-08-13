#!/usr/bin/env bash
# =============================================================================
# Phase 7e.1 — DIAGNOSTIC: dump the RAW Circle HTTP response (no fix)
# =============================================================================
#
# WHERE WE ARE (all verified):
#   * Wallet is EOA, LIVE, on Arc. Body matches Circle's Arc example exactly.
#   * API key authenticates; an entity secret IS registered (publicKey returns).
#   * Render has the same key + entity secret, from the new account.
#   * Yet every write fails: "API parameter invalid", errors:[].
#
#   Our logs only ever showed the SDK's PARSED view (err.response.data.errors).
#   That array is empty - but Circle's real reason may be in a different field,
#   and the HTTP STATUS CODE (400 vs 401 vs 403) alone would tell us whether
#   this is a validation error, an auth/entity-secret error, or a permission
#   error. The SDK (Axios) has all of it; we just weren't logging it.
#
# WHAT THIS ADDS (no behavior change to payouts):
#   1. sendUsdc catch: log the FULL raw error - HTTP status, statusText, the
#      ENTIRE response.data (not just .errors), and the request id header Circle
#      returns (x-request-id) for support. Still throws the same short reason.
#   2. GET /payroll/disbursement/selftest : from INSIDE the running service,
#      attempt a fee-estimate for a USDC transfer (a mutating-path call that
#      exercises the entity secret WITHOUT moving funds) and return the raw
#      result or raw error. Also reports the LENGTH of the loaded entity secret
#      and api key (lengths only - never values) so we can catch a trailing
#      newline / truncation in Render's env.
#
# SAFE: reads + a zero-value fee estimate only. No transfer. Idempotent
# (PHASE_7E1 marker). TEST LOCALLY (npm run build) BEFORE pushing.
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
API="$ROOT/afrifx-api"
DISB="$API/src/services/platformDisbursement.ts"
PAYROLL="$API/src/routes/payroll.ts"

[ -f "$DISB" ]    || { echo "ERR: $DISB not found"; exit 1; }
[ -f "$PAYROLL" ] || { echo "ERR: $PAYROLL not found"; exit 1; }

echo "==> Phase 7e.1: raw Circle response diagnostics"

# ----------------------------------------------------------------------------
# 1) richer catch logging + a selftest export in platformDisbursement.ts
# ----------------------------------------------------------------------------
python3 - "$DISB" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()

if 'PHASE_7E1' in s:
    print("   platformDisbursement.ts already patched (PHASE_7E1) - skipping")
    sys.exit(0)

# a) Upgrade the catch logging to dump the full raw error.
#    Match the 7e catch (contract execution). If not present, match generic.
old_log = "    console.error('[sendUsdc] Circle rejected contract execution:', JSON.stringify({\n      status:  err?.response?.status,\n      code:    data?.code,\n      message: data?.message,\n      errors,\n    }))"
new_log = """    // PHASE_7E1: dump EVERYTHING Circle sent back, not just .errors.
    console.error('[sendUsdc] RAW Circle error:', JSON.stringify({
      httpStatus:     err?.response?.status,
      httpStatusText: err?.response?.statusText,
      xRequestId:     err?.response?.headers?.['x-request-id'],
      responseData:   err?.response?.data,          // the ENTIRE body
      axiosCode:      err?.code,
      axiosMessage:   err?.message,
    }))"""
if old_log in s:
    s = s.replace(old_log, new_log)
else:
    # fall back to the pre-7e generic catch if 7e wasn't applied
    alt_old = "    const detail = err?.response?.data?.message ?? err?.message ?? 'transfer rejected'\n    throw new Error(detail)"
    if alt_old in s:
        alt_new = """    console.error('[sendUsdc] RAW Circle error:', JSON.stringify({
      httpStatus:     err?.response?.status,
      httpStatusText: err?.response?.statusText,
      xRequestId:     err?.response?.headers?.['x-request-id'],
      responseData:   err?.response?.data,
      axiosCode:      err?.code,
      axiosMessage:   err?.message,
    }))
    const detail = err?.response?.data?.message ?? err?.message ?? 'transfer rejected'
    throw new Error(detail)"""
        s = s.replace(alt_old, alt_new)
    else:
        sys.exit("ERR: could not find a sendUsdc catch block to enhance")

# b) Add a selftest export: fee-estimate a USDC transfer (exercises the entity
#    secret path, moves NO funds) + report secret/key lengths.
anchor = "/** Poll a payout's status by transaction id (to learn its on-chain hash). */"
if anchor not in s:
    anchor = "export async function getPayoutStatus"
if anchor not in s:
    sys.exit("ERR: could not find getPayoutStatus anchor")

selftest = '''// PHASE_7E1 (diagnostic): exercise the mutating-request path WITHOUT moving
// funds, and surface Circle's raw response. A fee-estimate for a USDC transfer
// hits the same auth/entity-secret machinery a real transfer does, so if the
// entity secret is mismatched this reproduces the failure with a readable
// error. Also returns loaded-credential LENGTHS (never values) to catch a
// trailing newline or truncation in the deployed env.
export async function disbursementSelfTest(walletId: string): Promise<any> {
  const apiKeyLen  = (process.env.CIRCLE_API_KEY ?? '').length
  const secretLen  = (process.env.CIRCLE_ENTITY_SECRET ?? '').length
  const secretHex  = /^[0-9a-fA-F]+$/.test(process.env.CIRCLE_ENTITY_SECRET ?? '')
  const out: any = {
    env: {
      apiKeyLength:        apiKeyLen,
      entitySecretLength:  secretLen,   // expect 64 (32-byte hex)
      entitySecretIsHex:   secretHex,   // expect true
      blockchain:          BLOCKCHAIN,
    },
  }
  try {
    const c = client()
    // estimateContractExecutionFee mirrors the real payout call, no funds move.
    const res = await (c as any).estimateContractExecutionFee({
      walletId,
      contractAddress:      process.env.CIRCLE_USDC_ERC20_ADDRESS ?? USDC_ADDRESS,
      abiFunctionSignature: 'transfer(address,uint256)',
      abiParameters:        [ '0x0000000000000000000000000000000000000001', '1' ],
    } as any)
    out.feeEstimate = res?.data ?? null
    out.ok = true
  } catch (err: any) {
    out.ok = false
    out.rawError = {
      httpStatus:     err?.response?.status,
      httpStatusText: err?.response?.statusText,
      xRequestId:     err?.response?.headers?.['x-request-id'],
      responseData:   err?.response?.data,
      axiosCode:      err?.code,
      axiosMessage:   err?.message,
    }
  }
  return out
}

'''
s = s.replace(anchor, selftest + anchor, 1)

# mark
s = s.replace('const BLOCKCHAIN =', '/* PHASE_7E1 diagnostics active */\nconst BLOCKCHAIN =', 1)

open(p, 'w', encoding='utf-8').write(s)
print("   platformDisbursement.ts patched (raw error dump + selftest)")
PY

# ----------------------------------------------------------------------------
# 2) route: GET /payroll/disbursement/selftest
# ----------------------------------------------------------------------------
python3 - "$PAYROLL" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()

if 'disbursement/selftest' in s:
    print("   payroll.ts already has /disbursement/selftest - skipping")
    sys.exit(0)

anchor = "export default router"
if anchor not in s:
    sys.exit("ERR: 'export default router' not found")

route = '''// GET /payroll/disbursement/selftest   (PHASE_7E1 diagnostic)
//
// From inside the running service: fee-estimate a USDC transfer (no funds
// move) to exercise the entity-secret/auth path and surface Circle's RAW
// response, plus loaded-credential lengths. This is the definitive check for
// an entity-secret mismatch or a truncated/newline-laden env value.
router.get('/disbursement/selftest', async (_req, res) => {
  const walletId = process.env.PAYROLL_DISBURSEMENT_WALLET_ID
  if (!walletId) return res.status(400).json({ error: 'Disbursement wallet not configured' })
  try {
    const { disbursementSelfTest } = await import('../services/platformDisbursement')
    res.json(await disbursementSelfTest(walletId))
  } catch (err: any) {
    res.status(502).json({ error: err.message })
  }
})

'''
s = s.replace(anchor, route + anchor)
open(p, 'w', encoding='utf-8').write(s)
print("   payroll.ts patched (added GET /disbursement/selftest)")
PY

echo "==> Type-checking afrifx-api"
cd "$API"
if [ -f node_modules/.bin/tsc ]; then
  npx tsc --noEmit && echo "   tsc: OK"
else
  echo "   (node_modules not installed here; run 'npm run build' locally before pushing)"
fi

cat <<'NEXT'

==> Phase 7e.1 applied (diagnostics only).

AFTER DEPLOY, RUN AND PASTE THE WHOLE THING:
    curl -s https://afrifx-api.onrender.com/payroll/disbursement/selftest | jq

READ IT LIKE THIS:
  * env.entitySecretLength  -> should be 64. If it's 65 (trailing newline),
    73+ (base64 pasted), or not 64, THAT is the bug - fix the Render env value.
  * env.entitySecretIsHex   -> should be true. If false, wrong value pasted
    (ciphertext or recovery-file content instead of the raw hex secret).
  * ok:true + feeEstimate    -> auth + entity secret are GOOD; the problem is
    specifically the transfer call shape, and rawError elsewhere will show it.
  * ok:false + rawError.httpStatus:
      401 -> entity secret / api key auth mismatch (the likely one)
      400 -> request validation (we read responseData for the real field)
      403 -> key lacks permission for this operation/chain
    rawError.responseData now holds Circle's FULL body, not just errors[].

Paste the full JSON. This tells us the actual cause instead of inferring it.
NEXT
