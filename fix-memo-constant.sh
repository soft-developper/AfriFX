#!/usr/bin/env bash
# Fix TS2304: ACCEPTED_APP_TAGS referenced in decodeMemoData but never defined
# (the Phase-A insert anchor didn't match your tree). This self-locates: it puts
# the constant just before the export that defines decodeMemoData, so it doesn't
# depend on any comment text. Idempotent.
set -euo pipefail
ROOT="$(pwd)"; FE="$ROOT/afrifx-web/lib/memo.ts"
[ -f "$FE" ] || { echo "ERROR: run from AfriFX repo root ($FE not found)"; exit 1; }

if grep -q "ACCEPTED_APP_TAGS =" "$FE"; then
  echo "• ACCEPTED_APP_TAGS already defined (skip)"
else
  # Insert the const on the line before `export function decodeMemoData`.
  perl -0pi -e "s{(export function decodeMemoData\()}{// Accept both tags during/after the AfriFX->Nexum rebrand. Past on-chain txs\n// are tagged 'afrifx' (immutable); 'nexum' is written only after the writer switch.\nexport const ACCEPTED_APP_TAGS = ['afrifx', 'nexum'] as const\n\n\$1}s" "$FE"
  if grep -q "ACCEPTED_APP_TAGS = \['afrifx', 'nexum'\] as const" "$FE"; then
    echo "✓ ACCEPTED_APP_TAGS inserted before decodeMemoData"
  else
    echo "✗ could not locate 'export function decodeMemoData(' — paste the file and I'll adjust"; exit 1
  fi
fi

# Sanity: definition now appears BEFORE the usage line.
DEF=$(grep -n "ACCEPTED_APP_TAGS =" "$FE" | head -1 | cut -d: -f1)
USE=$(grep -n "ACCEPTED_APP_TAGS.includes" "$FE" | head -1 | cut -d: -f1)
echo "  definition line: $DEF   usage line: $USE"
[ -n "$DEF" ] && [ -n "$USE" ] && [ "$DEF" -lt "$USE" ] && echo "  ✓ defined before used" || echo "  ⚠ check ordering"
