#!/usr/bin/env bash
# =============================================================================
# Phase 7d — Provision the payroll float as an EOA (not SCA); Arc-only payout
# =============================================================================
#
# WHY:
#   Every attempt to pay from the SCA float was rejected with "API parameter
#   invalid" and an EMPTY errors[] array - i.e. Circle rejected the request
#   before field validation, which points at the WALLET/shape, not the token.
#   The float was provisioned accountType:'SCA'. Circle's Arc transfer
#   quickstarts all use EOA, and SCA is the same account class failing the
#   Gateway 6c send over ERC-1271. An EOA has no contract code => plain
#   private-key signature => no ERC-1271/4337 path to reject.
#
#   On Arc the EOA "needs native gas" caveat is a non-issue: gas IS USDC, and
#   the float already holds USDC. So EOA is strictly better here, no downside.
#   (This is why we're keeping payroll ARC-ONLY - no per-chain native gas to
#   manage.)
#
# WHAT THIS SCRIPT CHANGES (code only - one wallet, nothing else on the
# platform; custody model, logins, user keys, escrow, bridge all untouched):
#   1. provisionDisbursementWallet(): accountType is now env-driven
#      (CIRCLE_ACCOUNT_TYPE, default 'EOA'). Comment corrected (was "SCA").
#   2. Balance gate (payroll execute route): add a small USDC gas-headroom
#      buffer (CIRCLE_GAS_BUFFER_USDC, default 0.05) so a batch funded to the
#      exact cent can't pass the gate then fail the last payout on gas.
#   3. Keeps 7c.3 full-error logging.
#
# WHAT YOU DO AFTER (touches funds/secrets - the script CAN'T and shouldn't):
#   a. Re-run the provision script -> new EOA wallet id + address:
#        cd afrifx-api && npx tsx src/scripts/provisionDisbursement.ts
#   b. Set the NEW PAYROLL_DISBURSEMENT_WALLET_ID in Render env.
#   c. Fund the new EOA address with testnet USDC (test batch total + a little).
#      (The old SCA float / its 40 test USDC is ABANDONED, as agreed.)
#   d. VERIFY before paying:
#        curl -s https://afrifx-api.onrender.com/payroll/disbursement/tokens | jq
#      Paste the output - we pick the correct tokenId from the NEW wallet
#      instead of assuming native-vs-ERC20 again.
#   e. Run a 1-2 recipient test batch and poll GET /payroll/batches/:id.
#
# SAFE TO RE-RUN: idempotent via the PHASE_7D marker.
# TEST LOCALLY (npm run build) BEFORE pushing.
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
API="$ROOT/afrifx-api"
DISB="$API/src/services/platformDisbursement.ts"
PAYROLL="$API/src/routes/payroll.ts"

[ -f "$DISB" ]    || { echo "ERR: $DISB not found (run from repo root)"; exit 1; }
[ -f "$PAYROLL" ] || { echo "ERR: $PAYROLL not found (run from repo root)"; exit 1; }

echo "==> Phase 7d: EOA disbursement wallet + gas-headroom gate"

# ----------------------------------------------------------------------------
# 1) accountType -> env-driven, default EOA
# ----------------------------------------------------------------------------
python3 - "$DISB" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()

if 'PHASE_7D' in s:
    print("   platformDisbursement.ts already patched (PHASE_7D) - skipping")
    sys.exit(0)

# a) add the ACCOUNT_TYPE constant next to the other env-driven consts.
anchor = "const USDC_ADDRESS =\n  process.env.CIRCLE_USDC_ADDRESS ?? '0x3600000000000000000000000000000000000000'"
if anchor not in s:
    sys.exit("ERR: USDC_ADDRESS const anchor not found")
addition = anchor + '''

// PHASE_7D: account type for the disbursement wallet. EOA is the default and
// the documented Arc payout path (SCA's ERC-1271 signature was rejected by
// Circle). Env-driven so the mainnet wallet can be provisioned without a code
// change; keep it EOA unless you have a specific reason for SCA.
const ACCOUNT_TYPE = (process.env.CIRCLE_ACCOUNT_TYPE ?? 'EOA').toUpperCase()'''
s = s.replace(anchor, addition)

# b) use it in createWallets + fix the stale "SCA" comment.
old_create = '''  const walletsRes = await c.createWallets({
    blockchains: [BLOCKCHAIN as any],
    count:       1,
    walletSetId,
    accountType: 'SCA',
  })'''
new_create = '''  const walletsRes = await c.createWallets({
    blockchains: [BLOCKCHAIN as any],
    count:       1,
    walletSetId,
    accountType: ACCOUNT_TYPE as any,   // PHASE_7D: EOA by default (see const)
  })'''
if old_create not in s:
    sys.exit("ERR: createWallets SCA block not found")
s = s.replace(old_create, new_create)

# c) correct the doc comment that says it creates an SCA wallet.
s = s.replace(
    'It creates a wallet set and a single SCA\n * wallet on the primary chain',
    'It creates a wallet set and a single wallet\n * (EOA by default, see ACCOUNT_TYPE) on the primary chain')

open(p, 'w', encoding='utf-8').write(s)
print("   platformDisbursement.ts patched (account type -> env-driven EOA)")
PY

# ----------------------------------------------------------------------------
# 2) gas-headroom on the balance gate
# ----------------------------------------------------------------------------
python3 - "$PAYROLL" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()

if 'PHASE_7D' in s:
    print("   payroll.ts already patched (PHASE_7D) - skipping")
    sys.exit(0)

old_gate = '''    // RULE 1 - balance gate: never start what the float can't finish.
    const { getDisbursementBalance } = await import('../services/platformDisbursement')
    const balance = await getDisbursementBalance(walletId)
    if (balance < owed) {
      return res.status(400).json({
        error: `Float balance (${balance} USDC) is less than the ${owed} USDC still owed in this batch. Top up the float first.`,
        code:  'insufficient_float',
        balance, owed,
      })
    }'''

new_gate = '''    // RULE 1 - balance gate: never start what the float can't finish.
    // PHASE_7D: on Arc gas is paid in USDC from this same wallet, so the float
    // must cover payouts PLUS a little gas. Require owed + a small buffer so a
    // batch funded to the exact cent can't pass here then fail the last payout
    // on gas. Buffer is tiny on Arc testnet; tune via CIRCLE_GAS_BUFFER_USDC.
    const gasBuffer = Number(process.env.CIRCLE_GAS_BUFFER_USDC ?? '0.05')
    const required  = owed + gasBuffer
    const { getDisbursementBalance } = await import('../services/platformDisbursement')
    const balance = await getDisbursementBalance(walletId)
    if (balance < required) {
      return res.status(400).json({
        error: `Float balance (${balance} USDC) is below the ${required} USDC needed (${owed} owed + ${gasBuffer} gas headroom) for this batch. Top up the float first.`,
        code:  'insufficient_float',
        balance, owed, gasBuffer, required,
      })
    }'''

if old_gate not in s:
    sys.exit("ERR: balance gate block not found (did the file change?)")
s = s.replace(old_gate, new_gate)

open(p, 'w', encoding='utf-8').write(s)
print("   payroll.ts patched (gas-headroom on balance gate)")
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

==> Phase 7d applied (code changes only).

NOW DO THE OPERATIONAL STEPS (in order):
  1. cd afrifx-api && npm run build            # must compile clean
  2. Re-provision the EOA wallet:
       npx tsx src/scripts/provisionDisbursement.ts
     -> copy the printed PAYROLL_DISBURSEMENT_WALLET_ID (new EOA wallet)
  3. Set that new PAYROLL_DISBURSEMENT_WALLET_ID in Render env, redeploy.
  4. Fund the NEW EOA address with testnet USDC (test-batch total + a bit).
  5. VERIFY the new wallet before paying:
       curl -s https://afrifx-api.onrender.com/payroll/disbursement/tokens | jq
     -> paste that output. We confirm the right USDC tokenId on the NEW wallet
        before running a batch (no assuming native-vs-ERC20 this time).
  6. Run a 1-2 recipient test batch; poll GET /payroll/batches/:id.

EXPECTED: recipients go 'paid'. If anything still fails, the red ERR: string +
the Render [sendUsdc] log now carry Circle's full error - paste it.

NOTE: this changed ONLY the payroll disbursement wallet. Custody model
(developer-controlled), user logins, user keys, escrow, bridge, and Gateway
are all untouched. Gateway Arc-only (7e) and the stuck bridge stay parked.
NEXT
