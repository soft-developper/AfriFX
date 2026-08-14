#!/usr/bin/env bash
# ============================================================
# rename-step3b-memo-writer.sh  —  AfriFX → Nexum, STEP 3 PHASE B (writer switch)
#
# PREREQUISITE: Phase A (accept-both decoders) MUST be live in production, and
# probe-memo-read-both.sh must pass. Phase B makes NEW transactions write the
# 'nexum' tag; the decoders (already accept-both from Phase A) read old + new.
#
# Verified safe scope (only these write the tag / build refs):
#   1. The ONE memo-writing call site: app: 'afrifx' -> 'nexum'
#      (backend only DECODES; no other writers exist — confirmed by grep)
#   2. buildMemoId seed  `afrifx-${seed}` -> `nexum-${seed}`  (hash preimage only)
#   3. buildReference()  `AFX-` -> `NEX-`  (user-visible refs; DB-only, not
#      on-chain; NO backend logic matches the AFX- prefix — confirmed)
#
# Existing AFX- refs and afrifx-tagged txs keep working unchanged.
# Idempotent. Run from repo root:  cd ~/AfriFX && bash rename-step3b-memo-writer.sh
# ============================================================
set -euo pipefail
ROOT="$(pwd)"
WEB="$ROOT/afrifx-web"
[ -d "$WEB" ] || { echo "ERROR: run from AfriFX repo root"; exit 1; }

MEMO="$WEB/lib/memo.ts"
[ -f "$MEMO" ] || { echo "ERROR: $MEMO not found"; exit 1; }

# --- SAFETY GATE: refuse to run if Phase A isn't present (would break new txs) ---
if ! grep -q "ACCEPTED_APP_TAGS" "$MEMO"; then
  echo "✗ ABORT: Phase A (accept-both decoder) not found in lib/memo.ts."
  echo "  Phase B must not ship before Phase A is live. Run Phase A first."
  exit 1
fi
echo "✓ Phase A present (accept-both decoder in place). Proceeding."
echo

# 1. The memo-writing call site(s): app: 'afrifx' -> 'nexum'
echo "→ 1/3  Switching memo writer tag 'afrifx' -> 'nexum'…"
mapfile -t SITES < <(grep -rl "app: 'afrifx'" --include=*.tsx --include=*.ts "$WEB" 2>/dev/null | grep -vE "node_modules|\.next")
if [ ${#SITES[@]} -eq 0 ]; then
  echo "  • no 'app: '\''afrifx'\''' writer sites found (already switched?)"
else
  for f in "${SITES[@]}"; do
    perl -0pi -e "s/app: 'afrifx'/app: 'nexum'/g" "$f"
    echo "  ✓ $(echo "$f" | sed "s#$ROOT/##")"
  done
fi

# 2. memoId seed prefix
echo "→ 2/3  buildMemoId seed 'afrifx-' -> 'nexum-'…"
if grep -q 'stringToHex(`afrifx-${seed}' "$MEMO"; then
  perl -0pi -e 's/stringToHex\(`afrifx-\$\{seed\}/stringToHex(`nexum-\$\{seed\}/' "$MEMO"
  echo "  ✓ memoId seed updated"
else
  echo "  • memoId seed already updated or not in expected form (skip)"
fi

# 3. buildReference prefix AFX- -> NEX-
echo "→ 3/3  buildReference() prefix 'AFX-' -> 'NEX-'…"
if grep -q 'return `AFX-\${date}-\${suffix}`' "$MEMO"; then
  perl -0pi -e 's/return `AFX-\$\{date\}-\$\{suffix\}`/return `NEX-\$\{date\}-\$\{suffix\}`/' "$MEMO"
  # update the doc comment too so it isn't stale/misleading
  perl -0pi -e 's/ref\?: string          \/\/ AFX-YYYYMMDD-XXXX/ref?: string          \/\/ NEX-YYYYMMDD-XXXX (legacy: AFX-)/' "$MEMO"
  echo "  ✓ reference prefix -> NEX-"
else
  echo "  • reference prefix already updated or not in expected form (skip)"
fi

echo
echo "→ Verify writer now emits nexum + NEX-:"
grep -n "app: 'nexum'\|nexum-\${seed}\|NEX-\${date}" "$WEB"/lib/memo.ts "$WEB"/components/invoice/InvoicePayInner.tsx 2>/dev/null | head
echo
echo "→ Confirm decoders STILL accept both (must be unchanged):"
grep -n "ACCEPTED_APP_TAGS = " "$WEB/lib/memo.ts" "$ROOT/afrifx-api/src/services/eventListener.ts"

echo
echo "Done (Step 3, Phase B). New txs write 'nexum'; old 'afrifx' txs still decode."
echo "Next:"
echo "  cd afrifx-web && rm -rf .next && npx tsc --noEmit && npm run build && cd .."
echo "  # test: make a NEW invoice payment on Arc, confirm the backend eventListener"
echo "  #        logs/records it (proves nexum write -> nexum read end-to-end)"
echo "  git add -A && git commit -m 'rebrand(step3b): memo writer emits nexum tag + NEX- refs (decoders read both)' && git push"
