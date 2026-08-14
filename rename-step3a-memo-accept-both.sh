#!/usr/bin/env bash
# ============================================================
# rename-step3a-memo-accept-both.sh  —  AfriFX → Nexum, STEP 3 PHASE A
#
# ON-CHAIN DATA SAFETY. The memo 'app' tag is written into Arc transaction
# memos and is IMMUTABLE for past transactions. Every historical AfriFX tx has
# {"app":"afrifx",...}. Two decoders read these:
#   • FE  afrifx-web/lib/memo.ts        decodeMemoData  (guard: app !== 'afrifx')
#   • BE  afrifx-api/.../eventListener.ts decodeMemo     (guard: app === 'afrifx')
# The BE listener is the one that records confirmed on-chain payments.
#
# PHASE A (this script): make BOTH decoders accept 'afrifx' OR 'nexum'.
#   After this ships and is confirmed live, past txs still decode AND any future
#   'nexum'-tagged tx will decode too.
#
# PHASE B (LATER, separate script — NOT here): switch the WRITER
#   (encodeMemoData / payload type) to emit 'nexum'. Must not ship until Phase A
#   is live in production, or new txs would write a tag the deployed decoder
#   still rejects — silently dropping payment metadata.
#
# This script does NOT change the writer, the memoId seed, or any on-chain call.
# Idempotent. Run from repo root:  cd ~/AfriFX && bash rename-step3a-memo-accept-both.sh
# ============================================================
set -euo pipefail
ROOT="$(pwd)"
[ -d "$ROOT/afrifx-web" ] && [ -d "$ROOT/afrifx-api" ] || { echo "ERROR: run from AfriFX repo root"; exit 1; }

FE="$ROOT/afrifx-web/lib/memo.ts"
BE="$ROOT/afrifx-api/src/services/eventListener.ts"
[ -f "$FE" ] && [ -f "$BE" ] || { echo "ERROR: memo files not found"; exit 1; }

echo "→ 1/3  Frontend decoder (lib/memo.ts): accept both tags…"
if grep -q "ACCEPTED_APP_TAGS" "$FE"; then
  echo "  • already accept-both (skip)"
else
  # Add a shared constant just above the payload interface.
  perl -0pi -e "s{(// ── AfriFX memo payload types)}{// ── Accepted app tags (rebrand: read both during and after AfriFX→Nexum) ──\n// Past on-chain txs are tagged 'afrifx' and are immutable; new txs will be\n// tagged 'nexum' only AFTER the writer switch (Phase B). Decoders read both.\nexport const ACCEPTED_APP_TAGS = ['afrifx', 'nexum'] as const\n\n\$1}s" "$FE"
  # Widen the payload literal type app:'afrifx' → app:'afrifx'|'nexum'
  perl -0pi -e "s/app:  'afrifx'/app:  'afrifx' | 'nexum'/s" "$FE"
  # Widen the decode guard
  perl -0pi -e "s/if \(parsed\.app !== 'afrifx'\) return null/if (!ACCEPTED_APP_TAGS.includes(parsed.app)) return null/s" "$FE"
  if grep -q "ACCEPTED_APP_TAGS.includes(parsed.app)" "$FE" && grep -q "app:  'afrifx' | 'nexum'" "$FE"; then
    echo "  ✓ FE decoder + type widened"
  else echo "  ✗ FE anchors not matched"; exit 1; fi
fi

echo "→ 2/3  Backend decoder (eventListener.ts): accept both tags…"
if grep -q "ACCEPTED_APP_TAGS" "$BE"; then
  echo "  • already accept-both (skip)"
else
  # Insert the constant just above the decodeMemo function.
  perl -0pi -e "s{(function decodeMemo\()}{// Accept both tags during/after the AfriFX->Nexum rebrand. Past on-chain txs\n// are tagged 'afrifx' (immutable); 'nexum' is written only after Phase B.\nconst ACCEPTED_APP_TAGS = ['afrifx', 'nexum']\n\n\$1}s" "$BE"
  perl -0pi -e "s/return parsed\.app === 'afrifx' \? parsed : null/return ACCEPTED_APP_TAGS.includes(parsed.app) ? parsed : null/s" "$BE"
  if grep -q "ACCEPTED_APP_TAGS.includes(parsed.app)" "$BE"; then
    echo "  ✓ BE decoder widened"
  else echo "  ✗ BE anchor not matched"; exit 1; fi
fi

echo "→ 3/3  SANITY — payload TYPE widened, WRITER call-sites unchanged (Phase B not done):"
grep -q "app:  'afrifx' | 'nexum'" "$FE" && echo "  ✓ payload type accepts both tags" || echo "  ⚠ type not widened"
# Call sites that BUILD payloads still set app:'afrifx' (writer unchanged this phase).
WRITES_NEXUM=$(grep -rn "app: 'nexum'\|app:'nexum'\|app: \"nexum\"" "$ROOT/afrifx-web" 2>/dev/null | grep -vE "node_modules|\.next|ACCEPTED_APP_TAGS" || true)
if [ -z "$WRITES_NEXUM" ]; then echo "  ✓ nothing writes 'nexum' yet (correct for Phase A)"; else echo "  ⚠ something already writes nexum:"; echo "$WRITES_NEXUM"; fi

echo
echo "→ Verify both decoders now list both tags:"
grep -n "ACCEPTED_APP_TAGS = " "$FE" "$BE"

echo
echo "Done (Step 3, Phase A). This is SAFE to deploy now — it only widens reading."
echo "Next:"
echo "  cd afrifx-api && npx tsc --noEmit && npm run build && cd .."
echo "  cd afrifx-web && rm -rf .next && npx tsc --noEmit && npm run build && cd .."
echo "  git add -A && git commit -m 'rebrand(step3a): memo decoders accept both afrifx+nexum tags (read-both)' && git push"
echo
echo "⚠ Do NOT run Phase B (writer→nexum) until this is confirmed live in prod."
