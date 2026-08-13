#!/usr/bin/env bash
# =============================================================================
# Phase 7g — Backfill real on-chain tx hashes + remove diagnostics
# =============================================================================
#
# WHY:
#   Payroll works. But rows store the Circle transaction *id* (a UUID) as a
#   fallback, because sendUsdc returns { id, state:INITIATED } - the on-chain
#   0x… hash isn't known yet at send time. ArcScan only accepts the 0x… hash,
#   so the UUID gives "request cannot be processed".
#
# WHAT THIS DOES:
#   1. FIRE-AND-BACKFILL: runBatchPayout sends every recipient first (fast),
#      recording the Circle tx id and marking them 'paid'. AFTER the send loop,
#      a second pass polls getPayoutStatus for each paid recipient and rewrites
#      tx_hash with the real 0x… hash once Circle reports it. A slow
#      confirmation on one recipient never blocks the others' payments.
#      Resilient: if a hash isn't ready in the poll window, the row keeps the
#      Circle id and a later re-execute backfills it.
#
#   2. CLEANUP: removes the diagnostics we added while debugging -
#      routes  /disbursement/tokens (7c.2), /disbursement/wallet-info (7d.1),
#              /disbursement/selftest (7e.1)
#      exports listWalletTokens, getDisbursementWalletInfo, disbursementSelfTest
#      logs    the [sendUsdc] body log and RAW-error dump
#      Each removal is CONDITIONAL - it only runs if that block is present, so
#      the script is safe whether or not a given diagnostic exists in your repo.
#
#   Keeps: the ERR: capture on failed rows (useful in prod) and the structured
#   error message surfaced to the recipient row.
#
# SAFE TO RE-RUN: idempotent via PHASE_7G marker + presence checks.
# TEST LOCALLY (npm run build) BEFORE pushing. Also: rm afrifx-api/probe.mjs
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
API="$ROOT/afrifx-api"
PAYROLL="$API/src/routes/payroll.ts"
DISB="$API/src/services/platformDisbursement.ts"

[ -f "$PAYROLL" ] || { echo "ERR: $PAYROLL not found (run from repo root)"; exit 1; }
[ -f "$DISB" ]    || { echo "ERR: $DISB not found (run from repo root)"; exit 1; }

echo "==> Phase 7g: backfill tx hashes + remove diagnostics"

# ----------------------------------------------------------------------------
# 1) Fire-and-backfill in runBatchPayout
# ----------------------------------------------------------------------------
python3 - "$PAYROLL" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()

if 'PHASE_7G' in s:
    print("   payroll.ts already patched (PHASE_7G) - skipping backfill")
    sys.exit(0)

# a) import getPayoutStatus alongside sendUsdc.
old_imp = "    const { sendUsdc } = await import('../services/platformDisbursement')"
new_imp = "    const { sendUsdc, getPayoutStatus } = await import('../services/platformDisbursement')  // PHASE_7G"
if old_imp not in s:
    sys.exit("ERR: sendUsdc import line not found in runBatchPayout")
s = s.replace(old_imp, new_imp, 1)

# b) after the send loop, before the settle block, insert the backfill pass.
settle_anchor = "    // Settle the batch status from the actual recipient outcomes."
if settle_anchor not in s:
    sys.exit("ERR: settle anchor not found")
backfill = '''    // PHASE_7G: backfill real on-chain hashes. The send loop above recorded
    // the Circle tx id (0x… hash isn't known at send time). Now poll each paid
    // recipient briefly and replace tx_hash with the real hash once Circle has
    // it. Bounded so a slow confirmation can't hang the batch; anything not
    // ready keeps its id and a later re-execute backfills it.
    const paidRows = parseRows(await db.run(sql`
      SELECT id, tx_hash FROM payroll_recipients
      WHERE batch_id = ${batchId} AND status = 'paid'`))
    for (const pr of paidRows) {
      const rid    = pr.id ?? pr[0]
      const stored = String(pr.tx_hash ?? pr[1] ?? '')
      if (stored.startsWith('0x')) continue          // already a real hash
      if (stored.startsWith('ERR:')) continue         // failed row, leave as-is
      const circleTxId = stored
      // Poll up to ~15s (5 tries x 3s) for the hash to appear.
      for (let attempt = 0; attempt < 5; attempt++) {
        try {
          const st = await getPayoutStatus(circleTxId)
          if (st.txHash) {
            await db.run(sql`
              UPDATE payroll_recipients SET tx_hash = ${st.txHash}
              WHERE id = ${rid}`).catch(() => {})
            break
          }
          if (['FAILED', 'DENIED', 'CANCELLED'].includes(st.state)) break
        } catch { /* transient - retry */ }
        await new Promise(r => setTimeout(r, 3000))
      }
    }

'''
s = s.replace(settle_anchor, backfill + settle_anchor, 1)

# mark
s = s.replace("async function runBatchPayout(batchId: string): Promise<void> {",
              "// PHASE_7G active\nasync function runBatchPayout(batchId: string): Promise<void> {", 1)

open(p, 'w', encoding='utf-8').write(s)
print("   payroll.ts patched (fire-and-backfill hash pass)")
PY

# ----------------------------------------------------------------------------
# 2) Remove diagnostics (each conditional on presence)
# ----------------------------------------------------------------------------
python3 - "$PAYROLL" "$DISB" <<'PY'
import re, sys
payroll_path, disb_path = sys.argv[1], sys.argv[2]

def strip_route(text, marker_comment):
    """Remove a `// <marker...>\\nrouter.<verb>('...', async ... })\\n\\n` block."""
    idx = text.find(marker_comment)
    if idx == -1:
        return text, False
    # find the router.<verb>( that follows, then match to its closing "})\n"
    r = text.find("router.", idx)
    if r == -1:
        return text, False
    # naive brace/paren-free approach: routes here end with "\n})\n"
    end = text.find("\n})\n", r)
    if end == -1:
        return text, False
    end += len("\n})\n")
    # also consume one trailing blank line if present
    if text[end:end+1] == "\n":
        end += 1
    return text[:idx] + text[end:], True

# --- payroll.ts: remove the three diagnostic routes -----------------------
pt = open(payroll_path, encoding='utf-8').read()
removed = []
for marker in [
    "// GET /payroll/disbursement/tokens   (PHASE_7C2 diagnostic)",
    "// GET /payroll/disbursement/wallet-info   (PHASE_7D1 diagnostic)",
    "// GET /payroll/disbursement/selftest   (PHASE_7E1 diagnostic)",
]:
    pt, did = strip_route(pt, marker)
    if did: removed.append(marker.split('/')[3].split()[0])
open(payroll_path, 'w', encoding='utf-8').write(pt)
print(f"   payroll.ts: removed routes -> {removed or 'none present'}")

# --- platformDisbursement.ts: remove diagnostic exports + logs ------------
dt = open(disb_path, encoding='utf-8').read()

def strip_export_fn(text, signature):
    """Remove an `export async function <sig> ... }\\n` block by brace matching."""
    idx = text.find(signature)
    if idx == -1:
        return text, False
    # walk from the first '{' after idx, matching braces to the function end.
    brace = text.find('{', idx)
    if brace == -1:
        return text, False
    depth = 0
    i = brace
    while i < len(text):
        if text[i] == '{': depth += 1
        elif text[i] == '}':
            depth -= 1
            if depth == 0:
                end = i + 1
                if text[end:end+1] == '\n': end += 1
                if text[end:end+1] == '\n': end += 1
                # also remove a leading doc-comment block immediately above idx
                start = idx
                pre = text.rfind('\n/**', 0, idx)
                if pre != -1 and text.count('*/', pre, idx) == 1:
                    start = pre + 1
                # or a leading // PHASE comment line
                cmt = text.rfind('\n//', 0, idx)
                if cmt != -1 and start == idx and idx - cmt < 200:
                    start = cmt + 1
                return text[:start] + text[end:], True
        i += 1
    return text, False

changed = []
for sig in [
    "export async function listWalletTokens(",
    "export async function getDisbursementWalletInfo(",
    "export async function disbursementSelfTest(",
]:
    dt, did = strip_export_fn(dt, sig)
    if did: changed.append(sig.split('function ')[1].split('(')[0])

# remove the debug body log + RAW error dump console lines if present.
patterns = [
    r"\n *console\.log\('\[sendUsdc\] createTransaction body:'.*?\)\n",
    r"\n *console\.log\('\[sendUsdc\] contractExecution body:'.*?\)\n",
    r"\n *const _debugBody = \{.*?\n *\}\n",
    r"\n *console\.error\('\[sendUsdc\] RAW Circle error:'.*?\}\)\)\n",
]
for pat in patterns:
    new = re.sub(pat, "\n", dt, flags=re.S)
    if new != dt:
        dt = new
        changed.append(pat[:30])

# clean the PHASE_7D1/7E1 "diagnostics active" banner comments if present.
for banner in [
    "/* PHASE_7D1 diagnostics active */\n",
    "/* PHASE_7E1 diagnostics active */\n",
]:
    if banner in dt:
        dt = dt.replace(banner, "")
        changed.append(banner.strip())

open(disb_path, 'w', encoding='utf-8').write(dt)
print(f"   platformDisbursement.ts: removed -> {changed or 'none present'}")
PY

# ----------------------------------------------------------------------------
# 3) Type-check (this catches any dangling reference to a removed diagnostic)
# ----------------------------------------------------------------------------
echo "==> Type-checking afrifx-api"
cd "$API"
if [ -f node_modules/.bin/tsc ]; then
  npx tsc --noEmit && echo "   tsc: OK" || {
    echo "   tsc FAILED - a removed diagnostic may still be referenced somewhere.";
    echo "   Check the error above; likely a leftover import or route registration."; }
else
  echo "   (node_modules not installed here; run 'npm run build' locally before pushing)"
fi

cat <<'NEXT'

==> Phase 7g applied.

VERIFY LOCALLY:
  1. cd afrifx-api && npm run build           # MUST compile clean
     If tsc complains about a missing export, a diagnostic route/import wasn't
     fully removed - tell me the error and I'll target it.
  2. Run a 1-2 recipient test batch from the app.
  3. Poll GET /payroll/batches/:id: recipients go 'paid', and within ~15s the
     tx_hash flips from the Circle UUID to a real 0x… hash.
  4. Paste that 0x… hash into https://testnet.arcscan.app/tx/<hash> - it
     resolves now.

ALSO:
  rm afrifx-api/probe.mjs        # the local reproduction script (has secrets via env)

NOTE: the /disbursement/tokens etc. routes are gone, so don't curl them after
this deploys. /disbursement/status and /disbursement/address remain (they're
part of the real funding flow, not diagnostics).
NEXT
