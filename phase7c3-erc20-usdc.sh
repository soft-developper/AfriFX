#!/usr/bin/env bash
# =============================================================================
# Phase 7c.3 — Transfer the ERC-20 USDC on Arc, not the native gas asset
# =============================================================================
#
# WHAT /payroll/disbursement/tokens REVEALED:
#   The wallet reports TWO USDC balances:
#     A) id 15dc... isNative:true  tokenAddress:null                 (gas asset)
#     B) id ef87... isNative:false tokenAddress:0x3600...0000        (ERC-20)
#   Both show amount 40.
#
# ROOT CAUSE:
#   Circle's Arc transfer flow moves USDC by calling the ERC-20 USDC contract
#   (the NON-native token). The native USDC entry is the GAS asset - you spend
#   it on fees, you don't token-transfer it. Our 7c.2 resolver matched the
#   FIRST entry (native) and Circle rejected a token-transfer of the gas asset
#   => "API parameter invalid" for every recipient.
#
# FIX:
#   resolveUsdcTokenId(): prefer the NON-native USDC entry (has a tokenAddress),
#   fall back to native only if that's all Circle returns. Cache real ids only.
#
#   Plus: log Circle's FULL error (data.errors[] + status), not just .message,
#   so any future rejection names the exact field instead of the generic text.
#   The short reason still lands in the recipient row as before.
#
# SAFE TO RE-RUN: idempotent via the PHASE_7C3 marker.
# TEST LOCALLY (npm run build) BEFORE pushing.
#
# IF THIS STILL FAILS with the ERC-20 token id, the remaining suspect is the
# SCA wallet type (Circle's Arc quickstarts all use EOA; SCA is the same class
# failing the Gateway 6c ERC-1271 path). That needs re-provisioning an EOA
# disbursement wallet - a bigger change we'd do as 7d, not a hot-patch.
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
API="$ROOT/afrifx-api"
DISB="$API/src/services/platformDisbursement.ts"

[ -f "$DISB" ] || { echo "ERR: $DISB not found (run from repo root)"; exit 1; }
grep -q "PHASE_7C2" "$DISB" || { echo "ERR: expected 7c.2 to be applied first"; exit 1; }

echo "==> Phase 7c.3: prefer ERC-20 USDC tokenId; add full-error logging"

python3 - "$DISB" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()

if 'PHASE_7C3' in s:
    print("   platformDisbursement.ts already patched (PHASE_7C3) - skipping")
    sys.exit(0)

# --- 1) replace the resolver body: prefer non-native USDC -------------------
old = '''  const match = balances.find(b => {
    const t = b.token ?? {}
    const sym  = String((t as any).symbol ?? '').toUpperCase()
    const addr = String((t as any).tokenAddress ?? '').toLowerCase()
    const native = (t as any).isNative === true
    // On Arc the native token IS USDC; elsewhere match the USDC symbol/address.
    return sym === 'USDC' || native || addr === USDC_ADDRESS.toLowerCase()
  })

  const id = (match?.token as any)?.id ? String((match!.token as any).id) : null
  if (id) _usdcTokenId = id   // cache real ids only
  return id'''

new = '''  // PHASE_7C3: on Arc the wallet holds TWO USDC entries - the NATIVE gas asset
  // (isNative:true, no address) and the ERC-20 USDC (isNative:false, has an
  // address). A USDC *transfer* goes through the ERC-20 contract, so we must
  // pick the NON-native entry. The native one is spent on gas, not transferred;
  // sending it as a token is what Circle rejected ("API parameter invalid").
  const usdc = balances.filter(b => {
    const t = (b.token ?? {}) as any
    const sym  = String(t.symbol ?? '').toUpperCase()
    const addr = String(t.tokenAddress ?? '').toLowerCase()
    return sym === 'USDC' || addr === USDC_ADDRESS.toLowerCase()
  })

  // Prefer the ERC-20 (non-native) USDC; fall back to whatever USDC exists.
  const pick =
    usdc.find(b => (b.token as any)?.isNative === false)
    ?? usdc.find(b => (b.token as any)?.isNative !== true)
    ?? usdc[0]

  const id = (pick?.token as any)?.id ? String((pick!.token as any).id) : null
  if (id) _usdcTokenId = id   // cache real ids only
  return id'''

if old not in s:
    sys.exit("ERR: 7c.2 resolver body not found (did the file change?)")
s = s.replace(old, new)

# --- 2) full-error logging in sendUsdc's catch ------------------------------
old_catch = '''  } catch (err: any) {
    // Surface Circle's actual rejection instead of a generic failure.
    const detail = err?.response?.data?.message ?? err?.message ?? 'transfer rejected'
    throw new Error(detail)
  }'''

new_catch = '''  } catch (err: any) {
    // PHASE_7C3: Circle returns a data.errors[] naming the exact bad field;
    // the top-level message is just "API parameter invalid". Log the full
    // structured error (once) so failures are diagnosable, then surface a
    // detailed-but-short reason to the caller/recipient row.
    const data   = err?.response?.data
    const errors = Array.isArray(data?.errors) ? data.errors : []
    const fieldMsgs = errors
      .map((e: any) => [e?.location, e?.message].filter(Boolean).join(': '))
      .filter(Boolean)
      .join('; ')
    console.error('[sendUsdc] Circle rejected transfer:', JSON.stringify({
      status:  err?.response?.status,
      code:    data?.code,
      message: data?.message,
      errors,
    }))
    const detail =
      fieldMsgs || data?.message || err?.message || 'transfer rejected'
    throw new Error(detail)
  }'''

if old_catch not in s:
    sys.exit("ERR: sendUsdc catch block not found (did the file change?)")
s = s.replace(old_catch, new_catch)

# mark
s = s.replace('// PHASE_7C2: resolve the Circle tokenId',
              '// PHASE_7C3 (supersedes 7C2): resolve the Circle tokenId', 1)

open(p, 'w', encoding='utf-8').write(s)
print("   platformDisbursement.ts patched (non-native USDC + full-error logging)")
PY

echo "==> Type-checking afrifx-api"
cd "$API"
if [ -f node_modules/.bin/tsc ]; then
  npx tsc --noEmit && echo "   tsc: OK"
else
  echo "   (node_modules not installed here; run 'npm run build' locally before pushing)"
fi

cat <<'NEXT'

==> Phase 7c.3 applied.

VERIFY LOCALLY, THEN RE-RUN A SMALL BATCH:
  1. cd afrifx-api && npm run build
  2. POST /payroll/batches/:id/execute   (a 1-2 recipient test batch)
  3. Poll GET /payroll/batches/:id

EXPECTED: recipients go 'paid'. If any still fail, the red ERR: string is now
the SPECIFIC field Circle rejected (from data.errors[]), and the Render log
line [sendUsdc] Circle rejected transfer: {...} has the full object. Paste
that and the next step is targeted.

IF IT STILL FAILS on the ERC-20 token id:
  the remaining suspect is the SCA wallet type. Circle's Arc transfer
  quickstarts all provision EOA wallets; SCA is the same account class failing
  your Gateway 6c ERC-1271 send. The fix there is to re-provision an EOA
  disbursement wallet and re-fund it - a 7d change, not a hot-patch. Say the
  word and I'll write it (it changes accountType:'SCA' -> 'EOA' in
  provisionDisbursementWallet and walks the re-provision/re-fund steps).
NEXT
