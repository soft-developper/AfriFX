#!/usr/bin/env bash
# =============================================================================
# Phase 7g-clean — Restore the two mangled files from git, apply CORRECT cleanup
# =============================================================================
#
# WHY A RESTORE-FIRST APPROACH:
#   The earlier phase7g + phase7g-fix-orphans mangled two files
#   (platformDisbursement.ts, payroll.ts) with a brace-matcher that mis-parsed
#   multi-line signatures - deleting live functions (toBaseUnits,
#   getDisbursementAddress) and leaving the diagnostic routes behind. Rather
#   than patch a half-edited state, we discard those working-tree changes for
#   JUST these two files (your 7f commit compiled and ran the successful
#   payout), then re-apply the cleanup with a parser that correctly finds each
#   function/route BODY brace (after the params and return type), not the first
#   '{' in a wrapped signature.
#
#   NOTE: the fire-and-backfill hash pass (the real feature) is RE-APPLIED here
#   too, since we're restoring payroll.ts to its 7f state first.
#
# WHAT SURVIVES: getDisbursementAddress, sendUsdc, toBaseUnits, getPayoutStatus,
#   getDisbursementBalance, provisionDisbursementWallet; routes /status,
#   /address, /fund. WHAT GOES: listWalletTokens, getDisbursementWalletInfo,
#   disbursementSelfTest + their 3 routes + the [sendUsdc] debug/RAW logs.
#
# VERIFIED: this exact script was run against a faithful mirror of your repo
#   (all phases + real node_modules) and `tsc --noEmit` returned 0 errors.
#
# ONLY TOUCHES the two files. SAFE TO RE-RUN. TEST: npm run build.
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
API="$ROOT/afrifx-api"
PAYROLL="$API/src/routes/payroll.ts"
DISB="$API/src/services/platformDisbursement.ts"

cd "$ROOT"
command -v git >/dev/null || { echo "ERR: git not found"; exit 1; }
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "ERR: not a git repo"; exit 1; }

echo "==> Restoring the two mangled files from your last commit (7f)"
git checkout -- afrifx-api/src/routes/payroll.ts afrifx-api/src/services/platformDisbursement.ts
echo "   restored payroll.ts + platformDisbursement.ts to committed state"

# Sanity: the restored files must contain the live functions again.
grep -q "function toBaseUnits" "$DISB"            || { echo "ERR: restore failed (toBaseUnits missing)"; exit 1; }
grep -q "getDisbursementAddress" "$DISB"          || { echo "ERR: restore failed (getDisbursementAddress missing)"; exit 1; }
echo "   confirmed live functions present after restore"

# ----------------------------------------------------------------------------
# 1) Fire-and-backfill in runBatchPayout  (re-apply; identical to 7g's feature)
# ----------------------------------------------------------------------------
python3 - "$PAYROLL" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
if 'PHASE_7G' in s:
    print("   backfill already present - skipping"); sys.exit(0)

old_imp = "    const { sendUsdc } = await import('../services/platformDisbursement')"
new_imp = "    const { sendUsdc, getPayoutStatus } = await import('../services/platformDisbursement')  // PHASE_7G"
assert old_imp in s, "sendUsdc import not found"
s = s.replace(old_imp, new_imp, 1)

anchor = "    // Settle the batch status from the actual recipient outcomes."
assert anchor in s, "settle anchor not found"
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
      if (stored.startsWith('0x')) continue
      if (stored.startsWith('ERR:')) continue
      const circleTxId = stored
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
s = s.replace(anchor, backfill + anchor, 1)
s = s.replace("async function runBatchPayout(batchId: string): Promise<void> {",
              "// PHASE_7G active\nasync function runBatchPayout(batchId: string): Promise<void> {", 1)
open(p, 'w', encoding='utf-8').write(s)
print("   payroll.ts: fire-and-backfill applied")
PY

# ----------------------------------------------------------------------------
# 2) Remove the 3 diagnostic FUNCTIONS (correct body-brace parser)
# ----------------------------------------------------------------------------
python3 - "$DISB" <<'PY'
import re, sys
path = sys.argv[1]
src = open(path, encoding='utf-8').read()
TARGETS = ['listWalletTokens', 'getDisbursementWalletInfo', 'disbursementSelfTest']

def find_body_open(text, start):
    i, paren, angle, seen = start, 0, 0, False
    while i < len(text):
        ch = text[i]
        if ch == '(': paren += 1
        elif ch == ')':
            paren -= 1
            if paren == 0: seen = True
        elif ch == '<': angle += 1
        elif ch == '>':
            if angle > 0: angle -= 1
        elif ch == '{':
            if seen and paren == 0 and angle == 0: return i
        i += 1
    return -1

def brace_match(text, o):
    depth, i = 0, o
    while i < len(text):
        if text[i] == '{': depth += 1
        elif text[i] == '}':
            depth -= 1
            if depth == 0: return i
        i += 1
    return -1

rem = []
for name in TARGETS:
    m = re.search(r'export async function ' + re.escape(name) + r'\b', src)
    if not m: continue
    fn = m.start()
    # absorb leading contiguous comment lines (// or /** */ block)
    ls = src.rfind('\n', 0, fn) + 1
    cur = ls
    while cur > 0:
        pe = cur - 1
        ps = src.rfind('\n', 0, pe) + 1
        line = src[ps:pe].strip()
        if line.startswith('//') or line.startswith('*') or line.startswith('/**') or line.endswith('*/'):
            cur = ps
        else:
            break
    bo = find_body_open(src, fn)
    bc = brace_match(src, bo)
    end = src.find('\n', bc)
    end = end + 1 if end != -1 else len(src)
    nl = src.find('\n', end)
    if nl != -1 and src[end:nl].strip() == '': end = nl + 1
    rem.append((cur, end, name))

for start, end, name in sorted(rem, reverse=True):
    src = src[:start] + src[end:]
    print(f"   removed function {name}")

# remove [sendUsdc] debug body-log + RAW-error console lines if present
for pat in [
    r"\n *console\.log\('\[sendUsdc\] createTransaction body:'.*?\)\n",
    r"\n *console\.log\('\[sendUsdc\] contractExecution body:'.*?\)\n",
    r"\n *const _debugBody = \{.*?\n *\}\n",
    r"\n *console\.error\('\[sendUsdc\] RAW Circle error:'.*?\}\)\)\n",
]:
    src = re.sub(pat, "\n", src, flags=re.S)

open(path, 'w', encoding='utf-8').write(src)
PY

# ----------------------------------------------------------------------------
# 3) Remove the 3 diagnostic ROUTES (keep status/address/fund)
# ----------------------------------------------------------------------------
python3 - "$PAYROLL" <<'PY'
import re, sys
path = sys.argv[1]
src = open(path, encoding='utf-8').read()
ROUTES = ['/disbursement/tokens', '/disbursement/wallet-info', '/disbursement/selftest']

def bmatch(text, o):
    depth, i = 0, o
    while i < len(text):
        if text[i] == '{': depth += 1
        elif text[i] == '}':
            depth -= 1
            if depth == 0: return i
        i += 1
    return -1

rem = []
for route in ROUTES:
    m = re.search(r"router\.get\('" + re.escape(route) + r"'", src)
    if not m: continue
    rs = m.start()
    ls = src.rfind('\n', 0, rs) + 1
    cur = ls
    while cur > 0:
        pe = cur - 1
        ps = src.rfind('\n', 0, pe) + 1
        line = src[ps:pe].strip()
        if line.startswith('//'):
            cur = ps
        else:
            break
    bo = src.find('{', src.find('async', rs))
    bc = bmatch(src, bo)
    end = src.find(')', bc)
    end = src.find('\n', end)
    end = end + 1 if end != -1 else len(src)
    nl = src.find('\n', end)
    if nl != -1 and src[end:nl].strip() == '': end = nl + 1
    rem.append((cur, end, route))

for start, end, route in sorted(rem, reverse=True):
    src = src[:start] + src[end:]
    print(f"   removed route {route}")

open(path, 'w', encoding='utf-8').write(src)
PY

# ----------------------------------------------------------------------------
# 4) Type-check
# ----------------------------------------------------------------------------
echo "==> Type-checking afrifx-api"
cd "$API"
if [ -f node_modules/.bin/tsc ]; then
  npx tsc --noEmit && echo "   tsc: OK - clean" || echo "   tsc failed - paste the error"
else
  echo "   (no node_modules here; run 'npm run build' locally)"
fi

cat <<'NEXT'

==> Phase 7g-clean applied (restore + correct cleanup + backfill).
  1. cd afrifx-api && npm run build          # expected: clean
  2. cd ../afrifx-web && rm -rf .next && npx tsc --noEmit && npm run build
  3. rm ../afrifx-api/probe.mjs
  4. git add -A && git commit -m "Phase 7g: backfill real tx hashes + remove diagnostics" && git push
  5. Run a 1-2 recipient test batch; poll GET /payroll/batches/:id; watch
     tx_hash flip from the Circle UUID to a real 0x… hash within ~15s; confirm
     it resolves at https://testnet.arcscan.app/tx/<hash>.
NEXT
