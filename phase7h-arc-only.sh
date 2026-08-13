#!/usr/bin/env bash
# =============================================================================
# Phase 7h — Arc-only payroll (remove the multi-chain picker)
# =============================================================================
#
# WHY:
#   Payouts always execute on Arc regardless of the chain selected, because the
#   payout engine sends from the Arc float wallet. Offering base/ethereum/
#   arbitrum/polygon in the UI promises something the code doesn't do. Until a
#   real cross-chain (Gateway) payout path exists, the honest UI is Arc-only.
#
# WHAT THIS DOES:
#   1. BACKEND: ALLOWED_CHAINS -> ['arc'] only; anything else is rejected.
#      destChain still defaults to 'arc'. The dest_chain column and the API
#      contract are UNCHANGED, so nothing downstream breaks and re-adding chains
#      later is a one-line revert.
#   2. FRONTEND: remove the "Payout chain" <select> from the create form.
#      destChain stays hard-set to 'arc' (HOME) in state, so the batch payload
#      is identical to picking Arc today. Drops the now-unused gatewayChains
#      import and the Layers icon if unused elsewhere.
#
#   NOT touched: the Gateway TREASURY features (balance panel, deposit) — those
#   are a separate, working system. This only removes the payroll chain PICKER.
#
# SAFE TO RE-RUN: idempotent via PHASE_7H markers / presence checks.
# TEST LOCALLY (both builds) BEFORE pushing.
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
API="$ROOT/afrifx-api"
WEB="$ROOT/afrifx-web"
PAYROLL="$API/src/routes/payroll.ts"
CREATE="$WEB/app/(app)/treasury/payroll/PayrollCreateContent.tsx"

[ -f "$PAYROLL" ] || { echo "ERR: $PAYROLL not found (run from repo root)"; exit 1; }
[ -f "$CREATE" ]  || { echo "ERR: $CREATE not found (run from repo root)"; exit 1; }

echo "==> Phase 7h: Arc-only payroll"

# ----------------------------------------------------------------------------
# 1) Backend: restrict ALLOWED_CHAINS to arc
# ----------------------------------------------------------------------------
python3 - "$PAYROLL" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()

old = "  const ALLOWED_CHAINS = ['arc', 'base', 'ethereum', 'arbitrum', 'polygon']"
new = "  const ALLOWED_CHAINS = ['arc']  // PHASE_7H: Arc-only until a real cross-chain payout path exists"
if old in s:
    s = s.replace(old, new, 1)
    open(p, 'w', encoding='utf-8').write(s)
    print("   backend: ALLOWED_CHAINS -> ['arc']")
elif "PHASE_7H" in s:
    print("   backend already Arc-only (PHASE_7H) - skipping")
else:
    print("   WARN: ALLOWED_CHAINS line not found as expected - leaving backend unchanged")
PY

# ----------------------------------------------------------------------------
# 2) Frontend: remove the payout-chain <select> block
# ----------------------------------------------------------------------------
python3 - "$CREATE" <<'PY'
import sys, re
p = sys.argv[1]
s = open(p, encoding='utf-8').read()

if 'PHASE_7H' in s:
    print("   frontend already patched (PHASE_7H) - skipping")
    sys.exit(0)

# Remove the whole <div> that contains the "Payout chain" label + select + hint.
# It starts at the <div> immediately before the `<Layers ... /> Payout chain`
# label and ends at the matching closing </div> after the hint <p>.
start_marker = '              <div>\n                <label className="mb-1 flex items-center gap-1.5 text-xs text-app-muted">\n                  <Layers className="h-3 w-3" /> Payout chain'
idx = s.find(start_marker)
if idx == -1:
    sys.exit("ERR: could not locate the Payout chain block start")

# find the end: the hint paragraph closes, then the block's </div>. We match
# forward to the FIRST '</div>\n' that follows the hint <p>...</p>.
hint_anchor = s.find('Each recipient is signed and minted on the destination chain.', idx)
if hint_anchor == -1:
    sys.exit("ERR: could not locate the Payout chain hint text")
close = s.find('</div>', hint_anchor)
if close == -1:
    sys.exit("ERR: could not locate the closing div for the picker")
end = close + len('</div>')
# swallow trailing newline
if s[end:end+1] == '\n':
    end += 1

removed_block = s[idx:end]
# Replace with a PHASE_7H marker comment (keeps a breadcrumb; renders nothing).
replacement = '              {/* PHASE_7H: payout-chain picker removed - Arc-only. destChain stays "arc". */}\n'
s = s[:idx] + replacement + s[end:]

# Drop the now-unused gatewayChains import.
s = s.replace("import { gatewayChains } from '@/lib/gateway'\n", "")

# Drop Layers from the lucide-react import if it's no longer used anywhere.
if 'Layers' not in s.replace("import { ArrowLeft, Plus, Trash2, Upload, Users, FileText, AlertCircle, CheckCircle, Layers } from 'lucide-react'", ""):
    s = s.replace(
        "import { ArrowLeft, Plus, Trash2, Upload, Users, FileText, AlertCircle, CheckCircle, Layers } from 'lucide-react'",
        "import { ArrowLeft, Plus, Trash2, Upload, Users, FileText, AlertCircle, CheckCircle } from 'lucide-react'",
        1)

open(p, 'w', encoding='utf-8').write(s)
print("   frontend: removed payout-chain picker (destChain stays 'arc')")
PY

# ----------------------------------------------------------------------------
# 3) Type-check both apps
# ----------------------------------------------------------------------------
echo "==> Type-checking afrifx-api"
( cd "$API" && [ -f node_modules/.bin/tsc ] && npx tsc --noEmit && echo "   api tsc: OK" || echo "   (api: run 'npm run build' locally)" )

echo "==> Type-checking afrifx-web"
( cd "$WEB" && [ -f node_modules/.bin/tsc ] && npx tsc --noEmit && echo "   web tsc: OK" || echo "   (web: run 'npm run build' locally)" )

cat <<'NEXT'

==> Phase 7h applied.
  1. cd afrifx-api && npm run build
  2. cd ../afrifx-web && rm -rf .next && npx tsc --noEmit && npm run build
  3. git add -A && git commit -m "Phase 7h: Arc-only payroll (remove multi-chain picker)" && git push

The create form no longer shows a chain selector; every batch is Arc. The
dest_chain column and API are unchanged, so re-adding chains later (once a real
Gateway payout path exists) is a small revert.
NEXT
