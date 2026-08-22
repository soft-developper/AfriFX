#!/usr/bin/env bash
# ============================================================
# ramp-phase5-fix-offramp-corridors-seed.sh
#
# FIX: off-ramp corridors endpoint returns {"offramp":[]} because migration
# 0024's corridor INSERT never executed on the prod Turso DB (recorded-as-
# applied but not run — same gap as transactions.from_chain in 0022/0023).
# Confirmed live: /ramp/corridors returns onramp rows, /ramp/offramp/corridors
# is empty, /ramp/health is green.
#
# APPROACH (self-heal at boot, not another migration): add
# ensureOfframpSchema() and call it once when the API starts. It runs
# CREATE TABLE IF NOT EXISTS for the two off-ramp tables + the six corridor
# rows via INSERT ... ON CONFLICT (direction,currency) DO NOTHING. Fully
# idempotent; repairs the seed on the next deploy and every deploy after.
#
# API-ONLY. Two changes under nexum-api:
#   NEW  src/services/bridgexyz/ensureOfframp.ts   (the self-heal function)
#   EDIT src/index.ts                              (import + call at boot)
#
# index.ts is patched SURGICALLY by anchor (two inserted lines), NOT replaced —
# your live boot sequence is preserved. Anchors:
#   import: the bridgexyz/client import line
#   call:   right after startBridgeReconciler()
# If an anchor isn't found (your index.ts differs), the script aborts with
# guidance rather than guessing.
#
# v2 delivery: base64 payload -> temp file -> decode -> verify before place.
# Idempotent (marker guards). --revert removes the file + un-patches index.ts.
#
# Usage:
#   bash ramp-phase5-fix-offramp-corridors-seed.sh          # apply
#   bash ramp-phase5-fix-offramp-corridors-seed.sh --revert # undo
# ============================================================
set -euo pipefail
STAMP="$(date +%Y%m%d-%H%M%S)"

if [ -d "nexum-api" ]; then API="nexum-api"
elif [ -d "../nexum-api" ]; then API="../nexum-api"
elif [ -f "package.json" ] && grep -q '"name": *"nexum-api"\|afrifx-api' package.json 2>/dev/null; then API="."
else echo "ERROR: run from the repo root (~/AfriFX) or nexum-api." >&2; exit 1; fi
echo "Using API package at: $API"

FIXFILE="$API/src/services/bridgexyz/ensureOfframp.ts"
INDEX="$API/src/index.ts"
FILE_MARKER="ensureOfframpSchema"
IMPORT_LINE="import { ensureOfframpSchema } from './services/bridgexyz/ensureOfframp'"
CALL_LINE="  await ensureOfframpSchema()"

if [ ! -f "$INDEX" ]; then echo "ERROR: $INDEX not found." >&2; exit 1; fi

# ---- revert -----------------------------------------------------------------
if [ "${1:-}" = "--revert" ]; then
  echo "Reverting off-ramp corridor seed fix..."
  BK="$(ls -t "$INDEX".bak.* 2>/dev/null | head -1 || true)"
  if [ -n "$BK" ]; then cp "$BK" "$INDEX"; echo "  restored $INDEX from $BK"
  else
    # Anchorless fallback: strip the two lines we added.
    grep -v "services/bridgexyz/ensureOfframp'" "$INDEX" | grep -v "await ensureOfframpSchema()" > "$INDEX.tmp" && mv "$INDEX.tmp" "$INDEX"
    echo "  no backup; stripped inserted lines from $INDEX"
  fi
  # Remove any leftover comment line we inserted above the call.
  grep -v "Self-heal the off-ramp corridor seed" "$INDEX" | grep -v "on prod Turso — see ensureOfframp.ts" | grep -v "Idempotent; safe on every boot." > "$INDEX.tmp" && mv "$INDEX.tmp" "$INDEX" || true
  if [ -f "$FIXFILE" ]; then rm -f "$FIXFILE"; echo "  removed $FIXFILE"; fi
  echo "Revert complete. Re-run: cd $API && npx tsc --noEmit && npm run build"
  exit 0
fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# ---- 1) place the new file --------------------------------------------------
if grep -q "$FILE_MARKER" "$FIXFILE" 2>/dev/null; then
  echo "  ensureOfframp.ts already present — skipping file"
else
cat > "$TMP/fix.b64" <<'B64FIX'
Ly8gPT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
PT09PT09Ci8vIEJvb3QtdGltZSBzZWxmLWhlYWwgZm9yIHRoZSBvZmYtcmFtcCBzY2hlbWEgKyBj
b3JyaWRvciBzZWVkLgovLwovLyBXSFkgVEhJUyBFWElTVFM6IG1pZ3JhdGlvbiAwMDI0J3MgY29y
cmlkb3IgSU5TRVJUIGRpZCBub3QgZXhlY3V0ZSBvbiB0aGUKLy8gcHJvZHVjdGlvbiBUdXJzbyBE
QiBldmVuIHRob3VnaCB0aGUgbWlncmF0aW9uIHdhcyByZWNvcmRlZCBhcyBhcHBsaWVkIOKAlCB0
aGUKLy8gc2FtZSAicmVjb3JkZWQtYnV0LW5vdC1ydW4iIGdhcCBzZWVuIHdpdGggdGhlIHRyYW5z
YWN0aW9ucy5mcm9tX2NoYWluIGNvbHVtbgovLyAoMDAyMi8wMDIzKS4gUmF0aGVyIHRoYW4gdHJ1
c3QgdGhlIG1pZ3JhdGlvbiBydW5uZXIsIHdlIGVuc3VyZSB0aGUgb2ZmLXJhbXAKLy8gdGFibGVz
IGFuZCB0aGUgc2l4IGNvcnJpZG9yIHJvd3MgZXhpc3QgZXZlcnkgdGltZSB0aGUgQVBJIGJvb3Rz
LgovLwovLyBTYWZlIGJ5IGNvbnN0cnVjdGlvbjogQ1JFQVRFIFRBQkxFIElGIE5PVCBFWElTVFMg
KyBJTlNFUlQgLi4uIE9OIENPTkZMSUNUCi8vIChkaXJlY3Rpb24sY3VycmVuY3kpIERPIE5PVEhJ
TkcuIElmIDAwMjQgYWxyZWFkeSBhcHBsaWVkIGNsZWFubHksIHRoaXMgaXMgYQovLyBuby1vcC4g
SWYgaXQgZGlkbid0LCB0aGlzIHJlcGFpcnMgaXQuIElkZW1wb3RlbnQgb24gZXZlcnkgZGVwbG95
LgovLwovLyBNaXJyb3JzIHRoZSBvbi1yYW1wIGNvcnJpZG9yIHNldCBidXQgYXMgdGhlIERFU1RJ
TkFUSU9OIHNpZGUuIHVzZC9ldXIvbXhuCi8vIGVuYWJsZWQgKHJhaWxzIHdpdGggYSBkZWZpbmVk
IGV4dGVybmFsLWFjY291bnQgc2hhcGUpOyBnYnAvYnJsL2NvcCBzZWVkZWQKLy8gZGlzYWJsZWQg
dW50aWwgdGhlaXIgZm9ybXMgc2hpcC4KLy8gPT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09CgppbXBvcnQgeyBkYiB9IGZyb20gJy4uLy4u
L2RiL2NsaWVudCcKaW1wb3J0IHsgc3FsIH0gZnJvbSAnZHJpenpsZS1vcm0nCgpleHBvcnQgYXN5
bmMgZnVuY3Rpb24gZW5zdXJlT2ZmcmFtcFNjaGVtYSgpOiBQcm9taXNlPHZvaWQ+IHsKICB0cnkg
ewogICAgLy8gMSkgVGFibGVzIChuby1vcCBpZiAwMDI0IGFscmVhZHkgY3JlYXRlZCB0aGVtKS4K
ICAgIGF3YWl0IGRiLnJ1bihzcWxgCiAgICAgIENSRUFURSBUQUJMRSBJRiBOT1QgRVhJU1RTIHJh
bXBfZXh0ZXJuYWxfYWNjb3VudHMgKAogICAgICAgIGlkICAgICAgICAgICAgICAgICAgICBURVhU
IFBSSU1BUlkgS0VZLAogICAgICAgIGFjY291bnRfaWQgICAgICAgICAgICBURVhUIE5PVCBOVUxM
LAogICAgICAgIHByb3ZpZGVyICAgICAgICAgICAgICBURVhUIE5PVCBOVUxMIERFRkFVTFQgJ2Jy
aWRnZXh5eicsCiAgICAgICAgY3VycmVuY3kgICAgICAgICAgICAgIFRFWFQgTk9UIE5VTEwsCiAg
ICAgICAgYnJpZGdlX2N1c3RvbWVyX2lkICAgIFRFWFQgTk9UIE5VTEwsCiAgICAgICAgZXh0ZXJu
YWxfYWNjb3VudF9pZCAgIFRFWFQgTk9UIE5VTEwsCiAgICAgICAgYmFua19uYW1lICAgICAgICAg
ICAgIFRFWFQsCiAgICAgICAgbGFzdF80ICAgICAgICAgICAgICAgIFRFWFQsCiAgICAgICAgYWNj
b3VudF90eXBlICAgICAgICAgIFRFWFQsCiAgICAgICAgY3JlYXRlZF9hdCAgICAgICAgICAgIElO
VEVHRVIgTk9UIE5VTEwsCiAgICAgICAgdXBkYXRlZF9hdCAgICAgICAgICAgIElOVEVHRVIgTk9U
IE5VTEwsCiAgICAgICAgVU5JUVVFIChhY2NvdW50X2lkLCBjdXJyZW5jeSkKICAgICAgKWApCiAg
ICBhd2FpdCBkYi5ydW4oc3FsYENSRUFURSBJTkRFWCBJRiBOT1QgRVhJU1RTIGlkeF9yYW1wX2V4
dF9hY2N0X2FjY291bnQgT04gcmFtcF9leHRlcm5hbF9hY2NvdW50cyAoYWNjb3VudF9pZClgKQog
ICAgYXdhaXQgZGIucnVuKHNxbGBDUkVBVEUgSU5ERVggSUYgTk9UIEVYSVNUUyBpZHhfcmFtcF9l
eHRfYWNjdF9icmlkZ2VfaWQgT04gcmFtcF9leHRlcm5hbF9hY2NvdW50cyAoZXh0ZXJuYWxfYWNj
b3VudF9pZClgKQoKICAgIGF3YWl0IGRiLnJ1bihzcWxgCiAgICAgIENSRUFURSBUQUJMRSBJRiBO
T1QgRVhJU1RTIHJhbXBfbGlxdWlkYXRpb25fYWRkcmVzc2VzICgKICAgICAgICBpZCAgICAgICAg
ICAgICAgICAgICAgICAgVEVYVCBQUklNQVJZIEtFWSwKICAgICAgICBhY2NvdW50X2lkICAgICAg
ICAgICAgICAgVEVYVCBOT1QgTlVMTCwKICAgICAgICBwcm92aWRlciAgICAgICAgICAgICAgICAg
VEVYVCBOT1QgTlVMTCBERUZBVUxUICdicmlkZ2V4eXonLAogICAgICAgIGN1cnJlbmN5ICAgICAg
ICAgICAgICAgICBURVhUIE5PVCBOVUxMLAogICAgICAgIGJyaWRnZV9jdXN0b21lcl9pZCAgICAg
ICBURVhUIE5PVCBOVUxMLAogICAgICAgIGxpcXVpZGF0aW9uX2FkZHJlc3NfaWQgICBURVhUIE5P
VCBOVUxMLAogICAgICAgIGV4dGVybmFsX2FjY291bnRfaWQgICAgICBURVhUIE5PVCBOVUxMLAog
ICAgICAgIGFkZHJlc3MgICAgICAgICAgICAgICAgICBURVhUIE5PVCBOVUxMLAogICAgICAgIHNv
dXJjZV9jaGFpbiAgICAgICAgICAgICBURVhUIE5PVCBOVUxMIERFRkFVTFQgJ2Jhc2UnLAogICAg
ICAgIHNvdXJjZV9jdXJyZW5jeSAgICAgICAgICBURVhUIE5PVCBOVUxMIERFRkFVTFQgJ3VzZGMn
LAogICAgICAgIGRlc3RpbmF0aW9uX3BheW1lbnRfcmFpbCBURVhUIE5PVCBOVUxMLAogICAgICAg
IGRlc3RpbmF0aW9uX2N1cnJlbmN5ICAgICBURVhUIE5PVCBOVUxMLAogICAgICAgIHN0YXR1cyAg
ICAgICAgICAgICAgICAgICBURVhUIE5PVCBOVUxMIERFRkFVTFQgJ2FjdGl2ZScsCiAgICAgICAg
Y3JlYXRlZF9hdCAgICAgICAgICAgICAgIElOVEVHRVIgTk9UIE5VTEwsCiAgICAgICAgdXBkYXRl
ZF9hdCAgICAgICAgICAgICAgIElOVEVHRVIgTk9UIE5VTEwsCiAgICAgICAgVU5JUVVFIChhY2Nv
dW50X2lkLCBjdXJyZW5jeSkKICAgICAgKWApCiAgICBhd2FpdCBkYi5ydW4oc3FsYENSRUFURSBJ
TkRFWCBJRiBOT1QgRVhJU1RTIGlkeF9yYW1wX2xpcV9hZGRyX2FjY291bnQgT04gcmFtcF9saXF1
aWRhdGlvbl9hZGRyZXNzZXMgKGFjY291bnRfaWQpYCkKICAgIGF3YWl0IGRiLnJ1bihzcWxgQ1JF
QVRFIElOREVYIElGIE5PVCBFWElTVFMgaWR4X3JhbXBfbGlxX2FkZHJfYnJpZGdlX2lkIE9OIHJh
bXBfbGlxdWlkYXRpb25fYWRkcmVzc2VzIChsaXF1aWRhdGlvbl9hZGRyZXNzX2lkKWApCiAgICBh
d2FpdCBkYi5ydW4oc3FsYENSRUFURSBJTkRFWCBJRiBOT1QgRVhJU1RTIGlkeF9yYW1wX2xpcV9h
ZGRyX2FkZHJlc3MgT04gcmFtcF9saXF1aWRhdGlvbl9hZGRyZXNzZXMgKGFkZHJlc3MpYCkKCiAg
ICAvLyAyKSBDb3JyaWRvciBzZWVkICh0aGUgcGllY2UgMDAyNCBmYWlsZWQgdG8gcnVuKS4gT04g
Q09ORkxJQ1Qga2VlcHMgaXQKICAgIC8vICAgIGlkZW1wb3RlbnQgYW5kIHdvbid0IGRpc3R1cmIg
YW55IHJvd3MgYW4gb3BlcmF0b3IgbGF0ZXIgZWRpdHMuCiAgICBhd2FpdCBkYi5ydW4oc3FsYAog
ICAgICBJTlNFUlQgSU5UTyByYW1wX2NvcnJpZG9ycwogICAgICAgIChpZCwgZGlyZWN0aW9uLCBj
dXJyZW5jeSwgbGFiZWwsIG1pbl9hbW91bnQsIGVuYWJsZWQsIHNvcnRfb3JkZXIsIGNyZWF0ZWRf
YXQsIHVwZGF0ZWRfYXQpCiAgICAgIFZBTFVFUwogICAgICAgICgnY29yX29mZnJhbXBfdXNkJywg
J29mZnJhbXAnLCAndXNkJywgJ1VTIERvbGxhciAoQUNIKScsICAgICAgICAxLCAxLCAxMCwgc3Ry
ZnRpbWUoJyVzJywnbm93JyksIHN0cmZ0aW1lKCclcycsJ25vdycpKSwKICAgICAgICAoJ2Nvcl9v
ZmZyYW1wX2V1cicsICdvZmZyYW1wJywgJ2V1cicsICdFdXJvIChTRVBBKScsICAgICAgICAgICAg
MSwgMSwgMjAsIHN0cmZ0aW1lKCclcycsJ25vdycpLCBzdHJmdGltZSgnJXMnLCdub3cnKSksCiAg
ICAgICAgKCdjb3Jfb2ZmcmFtcF9teG4nLCAnb2ZmcmFtcCcsICdteG4nLCAnTWV4aWNhbiBQZXNv
IChTUEVJKScsICAgIDEsIDEsIDQwLCBzdHJmdGltZSgnJXMnLCdub3cnKSwgc3RyZnRpbWUoJyVz
Jywnbm93JykpLAogICAgICAgICgnY29yX29mZnJhbXBfZ2JwJywgJ29mZnJhbXAnLCAnZ2JwJywg
J0JyaXRpc2ggUG91bmQgKEZQUyknLCAgICAxLCAwLCAzMCwgc3RyZnRpbWUoJyVzJywnbm93Jyks
IHN0cmZ0aW1lKCclcycsJ25vdycpKSwKICAgICAgICAoJ2Nvcl9vZmZyYW1wX2JybCcsICdvZmZy
YW1wJywgJ2JybCcsICdCcmF6aWxpYW4gUmVhbCAoUGl4KScsICAgMSwgMCwgNTAsIHN0cmZ0aW1l
KCclcycsJ25vdycpLCBzdHJmdGltZSgnJXMnLCdub3cnKSksCiAgICAgICAgKCdjb3Jfb2ZmcmFt
cF9jb3AnLCAnb2ZmcmFtcCcsICdjb3AnLCAnQ29sb21iaWFuIFBlc28gKEJyZS1CKScsIDEsIDAs
IDYwLCBzdHJmdGltZSgnJXMnLCdub3cnKSwgc3RyZnRpbWUoJyVzJywnbm93JykpCiAgICAgIE9O
IENPTkZMSUNUIChkaXJlY3Rpb24sIGN1cnJlbmN5KSBETyBOT1RISU5HYCkKCiAgICBjb25zdCBy
b3dzOiBhbnkgPSBhd2FpdCBkYi5ydW4oc3FsYFNFTEVDVCBDT1VOVCgqKSBBUyBjIEZST00gcmFt
cF9jb3JyaWRvcnMgV0hFUkUgZGlyZWN0aW9uID0gJ29mZnJhbXAnYCkKICAgIGNvbnN0IGNvdW50
ID0gcm93cz8ucm93cz8uWzBdPy5jID8/IHJvd3M/LlswXT8uYyA/PyAnPycKICAgIGNvbnNvbGUu
bG9nKGBbUmFtcF0gXHUyNzA1IG9mZi1yYW1wIHNjaGVtYSBlbnN1cmVkICgke2NvdW50fSBvZmYt
cmFtcCBjb3JyaWRvcnMgcHJlc2VudClgKQogIH0gY2F0Y2ggKGVycjogYW55KSB7CiAgICAvLyBO
ZXZlciBsZXQgYSBzZWVkIGZhaWx1cmUgY3Jhc2ggYm9vdCDigJQgbG9nIGFuZCBjb250aW51ZS4K
ICAgIGNvbnNvbGUuZXJyb3IoJ1tSYW1wXSBcdTI2YTAgZW5zdXJlT2ZmcmFtcFNjaGVtYSBmYWls
ZWQ6JywgZXJyPy5tZXNzYWdlID8/IGVycikKICB9Cn0K
B64FIX
if ! base64 --decode "$TMP/fix.b64" > "$TMP/ensureOfframp.ts" 2>/dev/null; then
  echo "ERROR: decode failed for ensureOfframp.ts — aborting." >&2; exit 1; fi
if [ ! -s "$TMP/ensureOfframp.ts" ] || ! grep -q "ensureOfframpSchema" "$TMP/ensureOfframp.ts"; then
  echo "ERROR: ensureOfframp.ts payload invalid — aborting." >&2; exit 1; fi
mkdir -p "$(dirname "$FIXFILE")"
cp "$TMP/ensureOfframp.ts" "$FIXFILE"
echo "  wrote $FIXFILE ($(wc -l < "$FIXFILE") lines)"
fi

# ---- 2) patch index.ts surgically ------------------------------------------
if grep -q "await ensureOfframpSchema()" "$INDEX" 2>/dev/null; then
  echo "  index.ts already calls ensureOfframpSchema — skipping patch"
else
  cp "$INDEX" "$INDEX.bak.$STAMP"

  # 2a) import — after the bridgexyz/client import if present, else after first import.
  if grep -q "from './services/bridgexyz/client'" "$INDEX"; then
    awk -v line="$IMPORT_LINE" '
      { print }
      /from '"'"'.\/services\/bridgexyz\/client'"'"'/ && !done { print line; done=1 }
    ' "$INDEX" > "$INDEX.tmp" && mv "$INDEX.tmp" "$INDEX"
  else
    echo "ERROR: could not find the bridgexyz/client import anchor in index.ts." >&2
    echo "       Add this import manually near the top:" >&2
    echo "         $IMPORT_LINE" >&2
    echo "       and this call inside app.listen(...), after your reconcilers:" >&2
    echo "         $CALL_LINE" >&2
    cp "$INDEX.bak.$STAMP" "$INDEX"; exit 1
  fi

  # 2b) call — after startBridgeReconciler() if present, else after startTransferReconciler().
  if grep -q "startBridgeReconciler()" "$INDEX"; then
    awk -v c="$CALL_LINE" '
      { print }
      /startBridgeReconciler\(\)/ && !done { print ""; print "  // Self-heal the off-ramp corridor seed (migration 0024 did not run on prod Turso)."; print c; done=1 }
    ' "$INDEX" > "$INDEX.tmp" && mv "$INDEX.tmp" "$INDEX"
  elif grep -q "startTransferReconciler()" "$INDEX"; then
    awk -v c="$CALL_LINE" '
      { print }
      /startTransferReconciler\(\)/ && !done { print ""; print "  // Self-heal the off-ramp corridor seed (migration 0024 did not run on prod Turso)."; print c; done=1 }
    ' "$INDEX" > "$INDEX.tmp" && mv "$INDEX.tmp" "$INDEX"
  else
    echo "ERROR: could not find a boot anchor (startBridgeReconciler/startTransferReconciler)." >&2
    echo "       Add this call manually inside app.listen(...):  $CALL_LINE" >&2
    cp "$INDEX.bak.$STAMP" "$INDEX"; exit 1
  fi

  # verify both landed
  if ! grep -q "await ensureOfframpSchema()" "$INDEX" || ! grep -q "ensureOfframp'" "$INDEX"; then
    echo "ERROR: index.ts patch verification failed — restoring backup." >&2
    cp "$INDEX.bak.$STAMP" "$INDEX"; exit 1; fi
  echo "  patched $INDEX (import + boot call; backup at $INDEX.bak.$STAMP)"
fi

echo ""
echo "Fix applied. Deploy:"
echo "  cd $API && npx tsc --noEmit && npm run build"
echo "  git add -A && git commit -m 'fix: self-heal offramp corridor seed at boot' && git push"
echo ""
echo "On Render boot you'll see: [Ramp] off-ramp schema ensured (6 off-ramp corridors present)"
echo "Then verify:  curl -s https://afrifx-api.onrender.com/ramp/offramp/corridors"
echo "Expect usd/eur/mxn."
