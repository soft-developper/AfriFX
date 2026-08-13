#!/usr/bin/env bash
# =============================================================================
# Phase 7g-fix — Repair orphaned function bodies from 7g's cleanup
# =============================================================================
#
# WHAT HAPPENED:
#   phase7g's export-removal used a brace matcher that mis-parsed multi-line
#   function signatures (the `{` it found belonged to a wrapped return type),
#   so it deleted each signature line but left the function BODY behind as an
#   orphan starting with a dangling `>> {` or `> {`. That's the TS1109 /
#   TS1005 wall of errors.
#
#   The backfill pass (PHASE_7G in payroll.ts) applied CORRECTLY and is intact.
#   Only platformDisbursement.ts has orphaned bodies, and they're dead code -
#   nothing references those removed exports (verified). So we delete each
#   orphaned block outright: from its dangling `>* {` opener through the
#   brace-matched closing `}`.
#
# SAFE TO RE-RUN: only acts on lines matching the dangling-opener pattern;
# once they're gone, it's a no-op.
# TEST LOCALLY (npm run build) BEFORE pushing.
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
API="$ROOT/afrifx-api"
DISB="$API/src/services/platformDisbursement.ts"

[ -f "$DISB" ] || { echo "ERR: $DISB not found (run from repo root)"; exit 1; }

echo "==> Phase 7g-fix: removing orphaned function bodies"

python3 - "$DISB" <<'PY'
import re, sys
p = sys.argv[1]
lines = open(p, encoding='utf-8').read().split('\n')

# An orphan opener is a line that is only `>`(one or more) + optional space + `{`
# at column 0 - the wreckage of a deleted signature whose body remains.
opener = re.compile(r'^>+\s*\{$')

out = []
i = 0
removed = 0
while i < len(lines):
    if opener.match(lines[i]):
        # brace-match from this line to its closing } at depth 0.
        depth = 0
        j = i
        while j < len(lines):
            depth += lines[j].count('{') - lines[j].count('}')
            if depth <= 0 and j > i:
                break
            j += 1
        # drop lines i..j inclusive, plus one trailing blank line if present.
        end = j + 1
        if end < len(lines) and lines[end].strip() == '':
            end += 1
        removed += 1
        print(f"   removed orphaned block: lines {i+1}-{j+1}")
        i = end
        continue
    out.append(lines[i])
    i += 1

if removed == 0:
    print("   no orphaned blocks found - nothing to repair")
else:
    open(p, 'w', encoding='utf-8').write('\n'.join(out))
    print(f"   repaired {removed} orphaned block(s)")
PY

echo "==> Type-checking afrifx-api"
cd "$API"
if [ -f node_modules/.bin/tsc ]; then
  npx tsc --noEmit && echo "   tsc: OK" || echo "   tsc still failing - paste the error"
else
  echo "   (node_modules not installed here; run 'npm run build' locally)"
fi

cat <<'NEXT'

==> Phase 7g-fix applied.
  1. cd afrifx-api && npm run build          # must compile clean now
  2. If clean, proceed with the test batch + deploy as before.
NEXT
