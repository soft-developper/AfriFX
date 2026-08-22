#!/usr/bin/env bash
# ============================================================
# fix-transactions-from-chain-boot-heal.sh
#
# FIX: cross-chain sends show "pending" forever + link to the Arc explorer.
# ROOT CAUSE (confirmed live): the transactions.from_chain column does NOT exist
# on prod — GET /transactions returns 11 rows, none carrying a from_chain key
# (SELECT * would expose it if the column existed). Migrations 0022 AND 0023
# were both recorded-as-applied but their ALTER TABLE never ran — the same
# "recorded-but-not-run" Turso gap fixed for the off-ramp corridor seed.
#
# Because the column is missing, POST /transactions uses its no-from_chain
# INSERT branch, so every send is stored with no chain → History defaults to the
# Arc explorer and the settle path can't resolve the chain → stuck "pending".
#
# The WEB side is already chain-aware (History reads from_chain w/ arc fallback;
# Send POSTs fromChain + settles on every chain) — those Aug 21 fixes were
# correct, they just never had a column to read. So this fix is API-ONLY:
# add the column at boot, independent of the broken migration runner.
#
# Two changes under nexum-api:
#   NEW  src/services/ensureTransactionsSchema.ts  (PRAGMA-guarded ALTER at boot)
#   EDIT src/index.ts                              (import + call at boot)
#
# index.ts is patched SURGICALLY by anchor, NOT replaced. Idempotent. --revert
# removes the file + un-patches index.ts. Old rows are NOT backfilled (per the
# Aug 21 decision) — they read from_chain=null and History uses the arc fallback.
#
# Usage:
#   bash fix-transactions-from-chain-boot-heal.sh          # apply
#   bash fix-transactions-from-chain-boot-heal.sh --revert # undo
# ============================================================
set -euo pipefail
STAMP="$(date +%Y%m%d-%H%M%S)"

if [ -d "nexum-api" ]; then API="nexum-api"
elif [ -d "../nexum-api" ]; then API="../nexum-api"
elif [ -f "package.json" ] && grep -q '"name": *"nexum-api"\|afrifx-api' package.json 2>/dev/null; then API="."
else echo "ERROR: run from the repo root (~/AfriFX) or nexum-api." >&2; exit 1; fi
echo "Using API package at: $API"

FIXFILE="$API/src/services/ensureTransactionsSchema.ts"
INDEX="$API/src/index.ts"
IMPORT_LINE="import { ensureTransactionsSchema } from './services/ensureTransactionsSchema'"
CALL_LINE="  await ensureTransactionsSchema()"

if [ ! -f "$INDEX" ]; then echo "ERROR: $INDEX not found." >&2; exit 1; fi

# ---- revert -----------------------------------------------------------------
if [ "${1:-}" = "--revert" ]; then
  echo "Reverting transactions from_chain boot-heal..."
  BK="$(ls -t "$INDEX".bak.* 2>/dev/null | head -1 || true)"
  if [ -n "$BK" ]; then cp "$BK" "$INDEX"; echo "  restored $INDEX from $BK"
  else
    grep -v "services/ensureTransactionsSchema" "$INDEX" | grep -v "await ensureTransactionsSchema()" > "$INDEX.tmp" && mv "$INDEX.tmp" "$INDEX"
    echo "  no backup; stripped inserted lines from $INDEX"
  fi
  grep -v "Self-heal transactions.from_chain" "$INDEX" > "$INDEX.tmp" 2>/dev/null && mv "$INDEX.tmp" "$INDEX" || true
  if [ -f "$FIXFILE" ]; then rm -f "$FIXFILE"; echo "  removed $FIXFILE"; fi
  echo "Revert complete. Re-run: cd $API && npx tsc --noEmit && npm run build"
  exit 0
fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# ---- 1) place the new file --------------------------------------------------
if grep -q "ensureTransactionsSchema" "$FIXFILE" 2>/dev/null; then
  echo "  ensureTransactionsSchema.ts already present — skipping file"
else
cat > "$TMP/fix.b64" <<'B64FIX'
Ly8gPT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
PT09PT09Ci8vIEJvb3QtdGltZSBzZWxmLWhlYWwgZm9yIHRoZSB0cmFuc2FjdGlvbnMuZnJvbV9j
aGFpbiBjb2x1bW4uCi8vCi8vIFdIWTogbWlncmF0aW9ucyAwMDIyIEFORCAwMDIzIHdlcmUgYm90
aCByZWNvcmRlZCBhcyBhcHBsaWVkIG9uIHRoZSBwcm9kCi8vIFR1cnNvIERCLCBidXQgdGhlIEFM
VEVSIFRBQkxFIG5ldmVyIGFjdHVhbGx5IHJhbiDigJQgdGhlIGZyb21fY2hhaW4gY29sdW1uIGlz
Ci8vIGFic2VudCAoY29uZmlybWVkOiBHRVQgL3RyYW5zYWN0aW9ucyByZXR1cm5zIDExIHJvd3Ms
IG5vbmUgY2FycnlpbmcgYQovLyBmcm9tX2NoYWluIGtleTsgU0VMRUNUICogd291bGQgZXhwb3Nl
IGl0IGlmIHRoZSBjb2x1bW4gZXhpc3RlZCkuIFRoaXMgaXMgdGhlCi8vIHNhbWUgInJlY29yZGVk
LWJ1dC1ub3QtcnVuIiBUdXJzbyBnYXAgc2VlbiB3aXRoIHRoZSBvZmYtcmFtcCBjb3JyaWRvciBz
ZWVkLgovLwovLyBDb25zZXF1ZW5jZSBvZiB0aGUgbWlzc2luZyBjb2x1bW46IFBPU1QgL3RyYW5z
YWN0aW9ucyBmYWxscyBiYWNrIHRvIGl0cwovLyBuby1mcm9tX2NoYWluIElOU0VSVCBicmFuY2gs
IHNvIGV2ZXJ5IHNlbmQgaXMgc3RvcmVkIHdpdGggbm8gY2hhaW4uIEhpc3RvcnkKLy8gdGhlbiBj
YW4ndCBwaWNrIHRoZSByaWdodCBibG9jayBleHBsb3JlciAoZGVmYXVsdHMgdG8gQXJjKSBhbmQg
dGhlIHNldHRsZQovLyBwYXRoIGNhbid0IHJlc29sdmUgdGhlIGNoYWluLCBsZWF2aW5nIGNyb3Nz
LWNoYWluIHNlbmRzIHN0dWNrICJwZW5kaW5nIi4KLy8KLy8gRklYOiBhZGQgdGhlIGNvbHVtbiBh
dCBib290IHZpYSBBTFRFUiBUQUJMRSwgZ3VhcmRlZCBzbyBpdCdzIGEgbm8tb3Agd2hlbiB0aGUK
Ly8gY29sdW1uIGFscmVhZHkgZXhpc3RzLiBJbmRlcGVuZGVudCBvZiB0aGUgbWlncmF0aW9uIHJ1
bm5lci4gSWRlbXBvdGVudC4KLy8gPT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
PT09PT09PT09PT09PT09PT09PT09PT09CgppbXBvcnQgeyBkYiB9IGZyb20gJy4uL2RiL2NsaWVu
dCcKaW1wb3J0IHsgc3FsIH0gZnJvbSAnZHJpenpsZS1vcm0nCgovKiogRG9lcyB0cmFuc2FjdGlv
bnMuZnJvbV9jaGFpbiBleGlzdCByaWdodCBub3c/ICovCmFzeW5jIGZ1bmN0aW9uIGNvbHVtbkV4
aXN0cygpOiBQcm9taXNlPGJvb2xlYW4+IHsKICB0cnkgewogICAgY29uc3QgaW5mbzogYW55ID0g
YXdhaXQgZGIucnVuKHNxbGBQUkFHTUEgdGFibGVfaW5mbyh0cmFuc2FjdGlvbnMpYCkKICAgIGNv
bnN0IHJvd3M6IGFueVtdID0gaW5mbz8ucm93cyA/PyBpbmZvID8/IFtdCiAgICByZXR1cm4gcm93
cy5zb21lKChjOiBhbnkpID0+IChjLm5hbWUgPz8gY1sxXSkgPT09ICdmcm9tX2NoYWluJykKICB9
IGNhdGNoIHsKICAgIHJldHVybiBmYWxzZQogIH0KfQoKLyoqCiAqIEVuc3VyZSB0cmFuc2FjdGlv
bnMuZnJvbV9jaGFpbiBleGlzdHMuIENhbGxlZCBvbmNlIGF0IGJvb3QsIGJlZm9yZSB0aGUgc2Vy
dmVyCiAqIGFjY2VwdHMgcmVxdWVzdHMuIFNhZmUgdG8gcnVuIGV2ZXJ5IGJvb3Q6IGlmIHRoZSBj
b2x1bW4gaXMgYWxyZWFkeSB0aGVyZSBpdAogKiBkb2VzIG5vdGhpbmc7IGlmIGEgY29uY3VycmVu
dCBhZGQgd2lucyB0aGUgcmFjZSwgdGhlICJkdXBsaWNhdGUgY29sdW1uIgogKiBlcnJvciBpcyBz
d2FsbG93ZWQuCiAqLwpleHBvcnQgYXN5bmMgZnVuY3Rpb24gZW5zdXJlVHJhbnNhY3Rpb25zU2No
ZW1hKCk6IFByb21pc2U8dm9pZD4gewogIHRyeSB7CiAgICBpZiAoYXdhaXQgY29sdW1uRXhpc3Rz
KCkpIHsKICAgICAgY29uc29sZS5sb2coJ1tUeF0gZnJvbV9jaGFpbiBjb2x1bW4gcHJlc2VudCcp
CiAgICAgIHJldHVybgogICAgfQogICAgdHJ5IHsKICAgICAgYXdhaXQgZGIucnVuKHNxbGBBTFRF
UiBUQUJMRSB0cmFuc2FjdGlvbnMgQUREIENPTFVNTiBmcm9tX2NoYWluIFRFWFRgKQogICAgICBj
b25zb2xlLmxvZygnW1R4XSBcdTI3MDUgYWRkZWQgdHJhbnNhY3Rpb25zLmZyb21fY2hhaW4gKHNl
bGYtaGVhbDsgbWlncmF0aW9ucyAwMDIyLzAwMjMgZGlkIG5vdCBydW4gb24gcHJvZCknKQogICAg
fSBjYXRjaCAoZTogYW55KSB7CiAgICAgIC8vIEFub3RoZXIgaW5zdGFuY2UgbWF5IGhhdmUgYWRk
ZWQgaXQgYmV0d2VlbiBvdXIgY2hlY2sgYW5kIGhlcmUuCiAgICAgIGlmICgvZHVwbGljYXRlIGNv
bHVtbi9pLnRlc3QoU3RyaW5nKGU/Lm1lc3NhZ2UgPz8gJycpKSkgewogICAgICAgIGNvbnNvbGUu
bG9nKCdbVHhdIGZyb21fY2hhaW4gYWxyZWFkeSBwcmVzZW50IChjb25jdXJyZW50IGFkZCknKQog
ICAgICB9IGVsc2UgewogICAgICAgIHRocm93IGUKICAgICAgfQogICAgfQogIH0gY2F0Y2ggKGVy
cjogYW55KSB7CiAgICAvLyBOZXZlciBjcmFzaCBib290IG92ZXIgdGhpcyDigJQgdGhlIGluc2Vy
dCBwYXRoIGRlZ3JhZGVzIGdyYWNlZnVsbHkgYW55d2F5LgogICAgY29uc29sZS5lcnJvcignW1R4
XSBcdTI2YTAgZW5zdXJlVHJhbnNhY3Rpb25zU2NoZW1hIGZhaWxlZDonLCBlcnI/Lm1lc3NhZ2Ug
Pz8gZXJyKQogIH0KfQo=
B64FIX
if ! base64 --decode "$TMP/fix.b64" > "$TMP/fix.ts" 2>/dev/null; then
  echo "ERROR: decode failed — aborting." >&2; exit 1; fi
if [ ! -s "$TMP/fix.ts" ] || ! grep -q "ensureTransactionsSchema" "$TMP/fix.ts"; then
  echo "ERROR: payload invalid — aborting." >&2; exit 1; fi
mkdir -p "$(dirname "$FIXFILE")"
cp "$TMP/fix.ts" "$FIXFILE"
echo "  wrote $FIXFILE ($(wc -l < "$FIXFILE") lines)"
fi

# ---- 2) patch index.ts surgically ------------------------------------------
if grep -q "await ensureTransactionsSchema()" "$INDEX" 2>/dev/null; then
  echo "  index.ts already calls ensureTransactionsSchema — skipping patch"
else
  cp "$INDEX" "$INDEX.bak.$STAMP"

  # import — after the bridgexyz/client import if present, else after first import line.
  if grep -q "from './services/bridgexyz/client'" "$INDEX"; then
    awk -v line="$IMPORT_LINE" '
      { print }
      /from '"'"'.\/services\/bridgexyz\/client'"'"'/ && !d { print line; d=1 }' "$INDEX" > "$INDEX.tmp" && mv "$INDEX.tmp" "$INDEX"
  else
    awk -v line="$IMPORT_LINE" 'NR==1{print line} {print}' "$INDEX" > "$INDEX.tmp" && mv "$INDEX.tmp" "$INDEX"
  fi

  # call — after startTransferReconciler() if present, else after app.listen open.
  if grep -q "startTransferReconciler()" "$INDEX"; then
    awk -v c="$CALL_LINE" '
      { print }
      /startTransferReconciler\(\)/ && !d { print ""; print "  // Self-heal transactions.from_chain (migrations 0022/0023 did not run on prod)."; print c; d=1 }' "$INDEX" > "$INDEX.tmp" && mv "$INDEX.tmp" "$INDEX"
  elif grep -q "app.listen(" "$INDEX"; then
    awk -v c="$CALL_LINE" '
      { print }
      /app\.listen\(/ && !d { print "  // Self-heal transactions.from_chain (migrations 0022/0023 did not run on prod)."; print c; d=1 }' "$INDEX" > "$INDEX.tmp" && mv "$INDEX.tmp" "$INDEX"
  else
    echo "ERROR: no boot anchor found (startTransferReconciler/app.listen)." >&2
    echo "       Add manually inside app.listen(...):  $CALL_LINE" >&2
    cp "$INDEX.bak.$STAMP" "$INDEX"; exit 1
  fi

  if ! grep -q "await ensureTransactionsSchema()" "$INDEX" || ! grep -q "services/ensureTransactionsSchema" "$INDEX"; then
    echo "ERROR: index.ts patch verification failed — restoring backup." >&2
    cp "$INDEX.bak.$STAMP" "$INDEX"; exit 1; fi
  echo "  patched $INDEX (import + boot call; backup at $INDEX.bak.$STAMP)"
fi

echo ""
echo "Fix applied. Deploy:"
echo "  cd $API && npx tsc --noEmit && npm run build"
echo "  git add -A && git commit -m 'fix: self-heal transactions.from_chain at boot' && git push"
echo ""
echo "On Render boot you'll see: [Tx] added transactions.from_chain (self-heal ...)"
echo "Then do a NEW cross-chain send (e.g. on Base) and check History —"
echo "it should link to the Base explorer and settle out of 'pending'."
echo "(Existing 11 rows stay Arc-linked; not backfilled, per the Aug 21 decision.)"
