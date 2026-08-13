#!/usr/bin/env bash
# =============================================================================
# Phase 7e — Pay USDC on Arc via CONTRACT EXECUTION (the actual fix)
# =============================================================================
#
# WHAT THE DIAGNOSTICS (7d.1) PROVED:
#   * Wallet IS EOA, LIVE, on ARC-TESTNET  (accountType:"EOA", scaCore:null)
#   * The createTransaction body was clean: valid walletId, tokenId ef87...,
#     destinationAddress, amount ["3"], standard fee.
#   * Circle STILL rejected it: "API parameter invalid", errors:[].
#
#   So it was never the token, the account type, or a malformed field. It was
#   the METHOD. Confirmed against Circle's own Arc docs + SDK:
#
#   Circle's canonical Arc USDC transfer does NOT use createTransaction. It uses
#   createContractExecutionTransaction, calling transfer(address,uint256) on the
#   USDC ERC-20 contract 0x3600...0000. On Arc, USDC is the native gas asset;
#   Circle's token-transfer endpoint won't do a plain tokenId transfer of it -
#   you move it through the ERC-20 interface. (Circle blog "Calling Smart
#   Contracts with Circle Wallets"; developers.circle.com Arc examples.)
#
#   DECIMALS TRAP (Circle skill + Arc docs, explicit):
#     Native USDC gas = 18 decimals; ERC-20 USDC interface = 6 decimals.
#     The ERC-20 transfer() takes 6-decimal units. So 3 USDC => "3000000".
#     Circle's example shows "1000000" for 1 USDC. We build this with INTEGER
#     math (no float rounding) to the smallest unit.
#
# WHAT THIS CHANGES:
#   sendUsdc() now calls createContractExecutionTransaction:
#     contractAddress:      USDC ERC-20 (0x3600...0000, env-overridable)
#     abiFunctionSignature: "transfer(address,uint256)"
#     abiParameters:        [destinationAddress, amountInBaseUnits]
#     fee:                  { type:'level', config:{ feeLevel:'MEDIUM' } }
#     idempotencyKey / refId: unchanged
#   Keeps full-error logging + the request-body log so any future failure is
#   readable. getPayoutStatus is unchanged (same tx lifecycle).
#
#   The old resolveUsdcTokenId / native-token path is no longer used by the
#   payout; left in place (harmless) for the /tokens diagnostic.
#
# SAFE TO RE-RUN: idempotent via PHASE_7E marker.
# TEST LOCALLY (npm run build) BEFORE pushing.
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
API="$ROOT/afrifx-api"
DISB="$API/src/services/platformDisbursement.ts"

[ -f "$DISB" ] || { echo "ERR: $DISB not found (run from repo root)"; exit 1; }

echo "==> Phase 7e: pay USDC on Arc via contract execution"

python3 - "$DISB" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()

if 'PHASE_7E' in s:
    print("   platformDisbursement.ts already patched (PHASE_7E) - skipping")
    sys.exit(0)

# Locate the whole sendUsdc body from its 'const c = client()' to the return.
start = s.find('export async function sendUsdc(params: {')
if start == -1:
    sys.exit("ERR: sendUsdc not found")
ret_anchor = "  const tx = res.data\n  if (!tx?.id) throw new Error('Circle did not return a transaction id')\n  return { id: String(tx.id), state: String(tx.state ?? 'INITIATED') }\n}"
ret_idx = s.find(ret_anchor, start)
if ret_idx == -1:
    sys.exit("ERR: sendUsdc return anchor not found")
block_end = ret_idx + len(ret_anchor)

new_send = '''export async function sendUsdc(params: {
  walletId:           string
  destinationAddress: string
  amount:             number
  idempotencyKey?:    string
  refId?:             string
}): Promise<PayoutResult> {
  const c = client()

  // PHASE_7E: On Arc, USDC is the native gas asset and Circle's token-transfer
  // endpoint (createTransaction) rejects a plain tokenId transfer of it. The
  // documented path is to call transfer(address,uint256) on the USDC ERC-20
  // contract via createContractExecutionTransaction.
  //
  // DECIMALS: the ERC-20 USDC interface on Arc uses 6 decimals (the NATIVE gas
  // representation uses 18 - do not use that here). Build the base-unit amount
  // with integer math so no float rounding can corrupt it.
  const USDC_ERC20 =
    process.env.CIRCLE_USDC_ERC20_ADDRESS ?? USDC_ADDRESS  // 0x3600...0000
  const DECIMALS = Number(process.env.CIRCLE_USDC_DECIMALS ?? '6')

  const baseUnits = toBaseUnits(params.amount, DECIMALS)
  if (baseUnits === null) {
    throw new Error(`Invalid payout amount: ${params.amount}`)
  }

  const _debugBody = {
    walletId:             params.walletId,
    contractAddress:      USDC_ERC20,
    abiFunctionSignature: 'transfer(address,uint256)',
    abiParameters:        [params.destinationAddress, baseUnits],
    amountHuman:          params.amount,
    decimals:             DECIMALS,
    fee:                  { type: 'level', config: { feeLevel: 'MEDIUM' } },
    refId:                params.refId ?? null,
  }
  console.log('[sendUsdc] contractExecution body:', JSON.stringify(_debugBody))

  let res
  try {
    res = await c.createContractExecutionTransaction({
      walletId:             params.walletId,
      contractAddress:      USDC_ERC20,
      abiFunctionSignature: 'transfer(address,uint256)',
      abiParameters:        [params.destinationAddress, baseUnits],
      idempotencyKey:       params.idempotencyKey ?? randomUUID(),
      fee: { type: 'level', config: { feeLevel: 'MEDIUM' } },
      ...(params.refId ? { refId: params.refId } : {}),
    } as any)
  } catch (err: any) {
    // Log Circle's FULL structured error (errors[] names the bad field when
    // present); surface a short but specific reason to the caller/recipient.
    const data   = err?.response?.data
    const errors = Array.isArray(data?.errors) ? data.errors : []
    const fieldMsgs = errors
      .map((e: any) => [e?.location, e?.message].filter(Boolean).join(': '))
      .filter(Boolean)
      .join('; ')
    console.error('[sendUsdc] Circle rejected contract execution:', JSON.stringify({
      status:  err?.response?.status,
      code:    data?.code,
      message: data?.message,
      errors,
    }))
    const detail = fieldMsgs || data?.message || err?.message || 'transfer rejected'
    throw new Error(detail)
  }

  const tx = res.data
  if (!tx?.id) throw new Error('Circle did not return a transaction id')
  return { id: String(tx.id), state: String(tx.state ?? 'INITIATED') }
}

/**
 * PHASE_7E: convert a human USDC amount to base units (string) using integer
 * math so floats can't round. Returns null for NaN/negative/over-precise input.
 * e.g. toBaseUnits(3, 6) -> "3000000";  toBaseUnits(1.5, 6) -> "1500000".
 */
function toBaseUnits(amount: number, decimals: number): string | null {
  if (!Number.isFinite(amount) || amount < 0) return null
  const s = amount.toString()
  if (s.includes('e') || s.includes('E')) return null  // reject sci-notation
  const [whole, frac = ''] = s.split('.')
  if (frac.length > decimals) return null               // more precision than the token allows
  const fracPadded = (frac + '0'.repeat(decimals)).slice(0, decimals)
  const combined = (whole + fracPadded).replace(/^0+(?=\\d)/, '')
  return combined === '' ? '0' : combined
}'''

s = s[:start] + new_send + s[block_end:]
open(p, 'w', encoding='utf-8').write(s)
print("   platformDisbursement.ts patched (sendUsdc -> contract execution, 6-decimal base units)")
PY

echo "==> Type-checking afrifx-api"
cd "$API"
if [ -f node_modules/.bin/tsc ]; then
  npx tsc --noEmit && echo "   tsc: OK"
else
  echo "   (node_modules not installed here; run 'npm run build' locally before pushing)"
fi

cat <<'NEXT'

==> Phase 7e applied.

VERIFY LOCALLY, THEN RUN A TEST BATCH:
  1. cd afrifx-api && npm run build
  2. Run a 1-2 recipient test batch from the app (or curl the execute route).
  3. Watch Render logs for:
       [sendUsdc] contractExecution body: {"...","abiParameters":["0x...","3000000"],...}
     Note the amount is now in 6-decimal base units (3 USDC -> "3000000").

  EXPECTED: recipients go 'paid'; the row tx_hash holds the Circle tx id, then
  the real on-chain hash once mined. Confirm on the Arc testnet explorer.

  IF it still fails, the log line
       [sendUsdc] Circle rejected contract execution: {...}
  now carries Circle's full error - paste it and it'll name the field.

WHY THIS SHOULD BE THE ONE: this matches Circle's own Arc USDC transfer example
exactly (createContractExecutionTransaction -> transfer() on 0x3600...0000, LOW/
MEDIUM feeLevel, 6-decimal amount). We're no longer using the endpoint that was
rejecting us; we're on the documented Arc path.
NEXT
