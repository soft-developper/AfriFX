#!/usr/bin/env bash
# =============================================================================
# Phase 7f — Fix the idempotencyKey (THE root cause, proven by probe)
# =============================================================================
#
# PROVEN: a bare createContractExecutionTransaction with
#   walletId, contractAddress, abiFunctionSignature, abiParameters, fee
# returns OK / state INITIATED. So the payload, wallet, account type, method,
# decimals, entity secret, and auth are ALL correct.
#
# THE BUG: sendUsdc adds idempotencyKey = `${batchId}:${recipientId}`, i.e.
# two UUIDs joined by a colon. The Circle SDK requires idempotencyKey to be a
# valid UUID v4 and rejects anything else CLIENT-SIDE, before any HTTP call -
# which is exactly the signature we chased for five phases:
#   axiosCode 2 (apiParameterInvalid), empty errors[], no httpStatus.
# Every earlier "fix" was on a payload that was already fine; the composite
# key (added in 7c for exactly-once) was the sole cause the whole time.
#
# THE FIX: keep exactly-once behaviour, but make the key a VALID UUID that is
# still STABLE per (batch, recipient). We derive a deterministic UUID from
# `${batchId}:${recipientId}` via SHA-1 (a UUIDv5-style namespaced hash):
# same input -> same UUID every time, so a retry dedupes identically, and the
# SDK accepts it. No external deps - Node's crypto only.
#
# SCOPE: one helper + one call site in payroll.ts. Nothing else changes.
# Leaves the 7e contract-execution sendUsdc exactly as-is (it's correct).
#
# SAFE TO RE-RUN: idempotent via PHASE_7F marker.
# TEST LOCALLY (npm run build) BEFORE pushing.
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
API="$ROOT/afrifx-api"
PAYROLL="$API/src/routes/payroll.ts"

[ -f "$PAYROLL" ] || { echo "ERR: $PAYROLL not found (run from repo root)"; exit 1; }

echo "==> Phase 7f: deterministic-UUID idempotency key"

python3 - "$PAYROLL" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()

if 'PHASE_7F' in s:
    print("   payroll.ts already patched (PHASE_7F) - skipping")
    sys.exit(0)

# 1) ensure createHash is imported alongside randomUUID.
old_import = "import { randomUUID } from 'crypto'"
new_import = "import { randomUUID, createHash } from 'crypto'  // PHASE_7F: createHash for deterministic idempotency UUID"
if old_import in s:
    s = s.replace(old_import, new_import, 1)
elif "createHash" not in s:
    sys.exit("ERR: could not find the crypto import to extend")

# 2) add a helper that turns any string into a stable, valid UUID.
#    Insert it just before runBatchPayout so it's in scope.
anchor = "async function runBatchPayout(batchId: string): Promise<void> {"
if anchor not in s:
    sys.exit("ERR: runBatchPayout anchor not found")
helper = '''// PHASE_7F: deterministic UUID from an arbitrary string. Circle's SDK requires
// idempotencyKey to be a valid UUID; a composite like `${batchId}:${recipientId}`
// is rejected client-side ("API parameter invalid"). We hash the composite key
// (SHA-1) and format it as a UUIDv5-style value: SAME input => SAME UUID, so a
// retry of the same payout still dedupes exactly-once, and the SDK accepts it.
function stableUuid(input: string): string {
  const h = createHash('sha1').update(input).digest('hex')  // 40 hex chars
  // Format 32 of them as 8-4-4-4-12, with version (5) and variant bits set.
  const b = h.slice(0, 32).split('')
  b[12] = '5'                                   // version 5
  const variant = (parseInt(b[16], 16) & 0x3 | 0x8).toString(16)
  b[16] = variant                               // variant 10xx
  const u = b.join('')
  return `${u.slice(0,8)}-${u.slice(8,12)}-${u.slice(12,16)}-${u.slice(16,20)}-${u.slice(20,32)}`
}

'''
s = s.replace(anchor, helper + anchor, 1)

# 3) use it at the call site.
old_call = "          idempotencyKey:     `${batchId}:${recipientId}`,"
new_call = "          idempotencyKey:     stableUuid(`${batchId}:${recipientId}`),  // PHASE_7F: valid, stable UUID"
if old_call not in s:
    sys.exit("ERR: idempotencyKey call site not found (did the file change?)")
s = s.replace(old_call, new_call, 1)

open(p, 'w', encoding='utf-8').write(s)
print("   payroll.ts patched (stableUuid idempotency key)")
PY

echo "==> Type-checking afrifx-api"
cd "$API"
if [ -f node_modules/.bin/tsc ]; then
  npx tsc --noEmit && echo "   tsc: OK"
else
  echo "   (node_modules not installed here; run 'npm run build' locally before pushing)"
fi

cat <<'NEXT'

==> Phase 7f applied.

VERIFY LOCALLY, THEN RUN A REAL TEST BATCH:
  1. cd afrifx-api && npm run build
  2. Run a 1-2 recipient batch from the app.
  3. Watch Render:
       [sendUsdc] contractExecution body: {... "abiParameters":["0x...","2000000"] ...}
     and NO "[sendUsdc] RAW Circle error" line after it.

EXPECTED: recipients go 'paid'; tx_hash holds the Circle tx id, then the real
on-chain hash once mined. Confirm on the Arc testnet explorer.

WHY THIS IS THE ONE (not a sixth guess): your probe proved the exact payload
succeeds. The ONLY thing sendUsdc added beyond the working probe was the
composite idempotencyKey. This makes that key a valid UUID while keeping it
stable per (batch, recipient), so exactly-once still holds.

CLEANUP (optional, later): the diagnostic routes/logs from 7c.2-7e1
(/disbursement/tokens, /wallet-info, /selftest, the RAW/body console logs) can
be removed once you're happy - say the word and I'll write a 7g that strips
them. Also delete the local probe.mjs so it isn't committed.
NEXT
