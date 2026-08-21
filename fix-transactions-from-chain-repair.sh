#!/usr/bin/env bash
# ============================================================================
# fix-transactions-from-chain-repair.sh
#
# REGRESSION REPAIR (API only). After fix-multichain-send-history.sh, Send
# stopped recording to History entirely, on ALL chains. Root cause traced to
# ground truth:
#   • The live transactions table has NO from_chain column — POST /transactions
#     returns: "SQLITE_UNKNOWN: table transactions has no column named
#     from_chain". Migration 0022 was RECORDED as applied on the production DB
#     but the ALTER TABLE never actually added the column.
#   • POST /transactions (the only insert path — used by Send + the two swap
#     hooks) always listed from_chain, so every insert threw → no record.
#     Bridges/P2P use different tables, which is why only Send looked broken.
#
# TWO-PART FIX:
#   • src/routes/transactions.ts (EDIT) — the insert now DETECTS whether the
#     from_chain column exists (PRAGMA table_info, cached) and includes it only
#     if present. So sends record again IMMEDIATELY on deploy, even before the
#     column lands. Once the column exists, the chain is stored as before.
#   • migrations/0023_transactions_from_chain_repair.sql (NEW) — re-adds the
#     column for real. Safe whether or not it exists (runner treats "duplicate
#     column" as already-applied). NULL = Arc, legacy rows unaffected.
#
# After deploy: Send records on every chain again; once 0023 runs, cross-chain
# sends also settle + link to the right explorer (the earlier fix's intent).
#
# Delivery: v2. Idempotent, backup, --revert. Verified: API tsc=0, insert
# proven BOTH ways (column absent → still records; present → stores chain),
# 0023 applies + is re-run-safe.
#
# Usage:
#   bash fix-transactions-from-chain-repair.sh           # apply
#   bash fix-transactions-from-chain-repair.sh --revert  # restore
# ============================================================================
set -euo pipefail

find_api_dir() {
  for d in "nexum-api" "afrifx-api" "." "../nexum-api" "../afrifx-api"; do
    if [ -f "$d/package.json" ] && [ -f "$d/src/routes/transactions.ts" ]; then (cd "$d" && pwd); return 0; fi
  done; return 1
}
API_DIR="$(find_api_dir || true)"
if [ -z "${API_DIR:-}" ]; then echo "✗ Could not find the API package." >&2; exit 1; fi
echo "• API: $API_DIR"

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$API_DIR/.fix-fromchain-repair-backup"
F_TR="src/routes/transactions.ts"
F_MIG="migrations/0023_transactions_from_chain_repair.sql"
M_TR="hasFromChainColumn"
M_MIG="from_chain"

if [ "${1:-}" = "--revert" ]; then
  if [ ! -d "$BACKUP_DIR" ]; then echo "✗ No backups." >&2; exit 1; fi
  LATEST="$(ls -1 "$BACKUP_DIR" | sed -n 's/^manifest-\(.*\)\.txt$/\1/p' | sort | tail -1 || true)"
  if [ -z "${LATEST:-}" ]; then echo "✗ No manifest." >&2; exit 1; fi
  while IFS='|' read -r kind rel; do
    [ -z "${kind:-}" ] && continue
    case "$kind" in
      EDIT) bak="$BACKUP_DIR/${rel//\//__}.$LATEST.bak"
            [ -f "$bak" ] && { cp -f "$bak" "$API_DIR/$rel"; echo "  ↺ restored $rel"; } || echo "  ⚠ missing backup $rel" >&2 ;;
      NEW)  [ -f "$API_DIR/$rel" ] && { rm -f "$API_DIR/$rel"; echo "  ✗ removed new $rel"; } ;;
    esac
  done < "$BACKUP_DIR/manifest-$LATEST.txt"
  echo "✓ Revert complete."; exit 0
fi

have() { [ -f "$API_DIR/$1" ] && grep -qF "$2" "$API_DIR/$1"; }
if have "$F_TR" "$M_TR" && have "$F_MIG" "$M_MIG"; then
  echo "✓ Repair already applied. Nothing to do."; exit 0
fi

mkdir -p "$BACKUP_DIR"
MANIFEST="$BACKUP_DIR/manifest-$STAMP.txt"; : > "$MANIFEST"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

decode_verify() {
  local b64="$1" out="$2" marker="$3" label="$4"
  base64 --decode "$b64" > "$out" 2>/dev/null || { echo "✗ [$label] decode failed." >&2; exit 1; }
  [ -s "$out" ] || { echo "✗ [$label] empty." >&2; exit 1; }
  grep -qF "$marker" "$out" || { echo "✗ [$label] marker missing." >&2; exit 1; }
}
place_new()  { local o="$1" r="$2"; mkdir -p "$(dirname "$API_DIR/$r")"; cp -f "$o" "$API_DIR/$r"; echo "NEW|$r" >> "$MANIFEST"; echo "  + wrote $r (new)"; }
place_edit() { local o="$1" r="$2"; [ -f "$API_DIR/$r" ] || { echo "✗ Missing $r" >&2; exit 1; }; cp -f "$API_DIR/$r" "$BACKUP_DIR/${r//\//__}.$STAMP.bak"; echo "EDIT|$r" >> "$MANIFEST"; cp -f "$o" "$API_DIR/$r"; echo "  ~ updated $r"; }

echo "• Applying from_chain repair …"

# ---- FX2TR ----
cat > "$WORK/FX2TR.b64" <<'B64_FX2TR'
aW1wb3J0IHsgUm91dGVyIH0gZnJvbSAnZXhwcmVzcycKaW1wb3J0IHsgZGIgfSAgICAgZnJvbSAn
Li4vZGIvY2xpZW50JwppbXBvcnQgeyBzcWwgfSAgICBmcm9tICdkcml6emxlLW9ybScKCmNvbnN0
IHJvdXRlciA9IFJvdXRlcigpCgpmdW5jdGlvbiBwYXJzZVJvd3MocjogYW55KTogYW55W10gewog
IGlmICghcikgcmV0dXJuIFtdCiAgaWYgKEFycmF5LmlzQXJyYXkoKHIgYXMgYW55KS5yb3dzKSkg
cmV0dXJuIChyIGFzIGFueSkucm93cwogIGlmIChBcnJheS5pc0FycmF5KHIpKSByZXR1cm4gcgog
IHJldHVybiBbXQp9CgovLyBXaGV0aGVyIHRoZSB0cmFuc2FjdGlvbnMgdGFibGUgaGFzIHRoZSBm
cm9tX2NoYWluIGNvbHVtbi4gRGV0ZWN0ZWQgb25jZSBhbmQKLy8gY2FjaGVkLiBUaGlzIG1ha2Vz
IHRoZSBpbnNlcnQgcmVzaWxpZW50OiBpZiB0aGUgMDAyMi8wMDIzIG1pZ3JhdGlvbiBoYXNuJ3QK
Ly8gbGFuZGVkIG9uIHRoaXMgZGF0YWJhc2UgeWV0LCB3ZSBzaW1wbHkgb21pdCB0aGUgY29sdW1u
IGluc3RlYWQgb2YgdGhyb3dpbmcKLy8gKHdoaWNoIHdvdWxkIGRyb3AgdGhlIHdob2xlIHNlbmQg
cmVjb3JkKS4gUmUtY2hlY2tlZCBsYXppbHkgdW50aWwgZm91bmQuCmxldCBfZnJvbUNoYWluQ29s
OiBib29sZWFuIHwgbnVsbCA9IG51bGwKYXN5bmMgZnVuY3Rpb24gaGFzRnJvbUNoYWluQ29sdW1u
KCk6IFByb21pc2U8Ym9vbGVhbj4gewogIGlmIChfZnJvbUNoYWluQ29sID09PSB0cnVlKSByZXR1
cm4gdHJ1ZQogIHRyeSB7CiAgICBjb25zdCBpbmZvID0gYXdhaXQgZGIucnVuKHNxbGBQUkFHTUEg
dGFibGVfaW5mbyh0cmFuc2FjdGlvbnMpYCkKICAgIGNvbnN0IGNvbHMgPSBwYXJzZVJvd3MoaW5m
bykubWFwKChjOiBhbnkpID0+IGMubmFtZSkKICAgIF9mcm9tQ2hhaW5Db2wgPSBjb2xzLmluY2x1
ZGVzKCdmcm9tX2NoYWluJykKICB9IGNhdGNoIHsKICAgIF9mcm9tQ2hhaW5Db2wgPSBmYWxzZQog
IH0KICByZXR1cm4gX2Zyb21DaGFpbkNvbCA9PT0gdHJ1ZQp9CgovLyBHRVQgL3RyYW5zYWN0aW9u
cz93YWxsZXQ9MHgKcm91dGVyLmdldCgnLycsIGFzeW5jIChyZXEsIHJlcykgPT4gewogIGNvbnN0
IHdhbGxldCA9IChyZXEucXVlcnkud2FsbGV0IGFzIHN0cmluZyk/LnRvTG93ZXJDYXNlKCkKICBp
ZiAoIXdhbGxldCkgcmV0dXJuIHJlcy5zdGF0dXMoNDAwKS5qc29uKHsgZXJyb3I6ICd3YWxsZXQg
cmVxdWlyZWQnIH0pCiAgdHJ5IHsKICAgIGNvbnN0IHJvd3MgPSBhd2FpdCBkYi5ydW4oCiAgICAg
IHNxbGBTRUxFQ1QgKiBGUk9NIHRyYW5zYWN0aW9ucwogICAgICAgICAgV0hFUkUgTE9XRVIod2Fs
bGV0X2FkZHJlc3MpID0gJHt3YWxsZXR9CiAgICAgICAgICBPUkRFUiBCWSBjcmVhdGVkX2F0IERF
U0MgTElNSVQgNTBgCiAgICApCiAgICByZXMuanNvbihwYXJzZVJvd3Mocm93cykpCiAgfSBjYXRj
aCAoZXJyOiBhbnkpIHsgcmVzLnN0YXR1cyg1MDApLmpzb24oeyBlcnJvcjogZXJyLm1lc3NhZ2Ug
fSkgfQp9KQoKLy8gUE9TVCAvdHJhbnNhY3Rpb25zIGNyZWF0ZQpyb3V0ZXIucG9zdCgnLycsIGFz
eW5jIChyZXEsIHJlcykgPT4gewogIGNvbnN0IHsKICAgIHdhbGxldEFkZHJlc3MsIGZyb21DdXJy
ZW5jeSwgdG9DdXJyZW5jeSwKICAgIGZyb21BbW91bnQsIHRvQW1vdW50LCBzcHJlYWRGZWUsIG5l
dHdvcmtGZWUsCiAgICBhcmNUeEhhc2gsIG1lbW9JZCwgcmVmZXJlbmNlLCBjb3JyaWRvcklkLCBj
b3JyaWRvclN0ZXAsCiAgICBmcm9tQ2hhaW4sCiAgfSA9IHJlcS5ib2R5CgogIGNvbnN0IG5vdyA9
IE1hdGguZmxvb3IoRGF0ZS5ub3coKSAvIDEwMDApCiAgY29uc3QgaWQgID0gYXJjVHhIYXNoID8/
IGB0eC0ke25vd30tJHtNYXRoLnJhbmRvbSgpLnRvU3RyaW5nKDM2KS5zbGljZSgyLDgpfWAKCiAg
dHJ5IHsKICAgIC8vIEluY2x1ZGUgZnJvbV9jaGFpbiBvbmx5IGlmIHRoZSBjb2x1bW4gZXhpc3Rz
IG9uIHRoaXMgREIgKHNlZSAwMDIzKS4gVGhpcwogICAgLy8ga2VlcHMgc2VuZHMgcmVjb3JkaW5n
IGV2ZW4gaWYgdGhlIGNvbHVtbiBtaWdyYXRpb24gaGFzbid0IGxhbmRlZCB5ZXQuCiAgICBpZiAo
YXdhaXQgaGFzRnJvbUNoYWluQ29sdW1uKCkpIHsKICAgICAgYXdhaXQgZGIucnVuKAogICAgICAg
IHNxbGBJTlNFUlQgT1IgSUdOT1JFIElOVE8gdHJhbnNhY3Rpb25zCiAgICAgICAgICAgIChpZCwg
d2FsbGV0X2FkZHJlc3MsIGZyb21fY3VycmVuY3ksIHRvX2N1cnJlbmN5LAogICAgICAgICAgICAg
ZnJvbV9hbW91bnQsIHRvX2Ftb3VudCwgc3ByZWFkX2ZlZSwgbmV0d29ya19mZWUsCiAgICAgICAg
ICAgICBhcmNfdHhfaGFzaCwgbWVtb19pZCwgcmVmZXJlbmNlLAogICAgICAgICAgICAgY29ycmlk
b3JfaWQsIGNvcnJpZG9yX3N0ZXAsIGZyb21fY2hhaW4sIHN0YXR1cywgY3JlYXRlZF9hdCkKICAg
ICAgICAgICAgVkFMVUVTCiAgICAgICAgICAgICgke2lkfSwgJHt3YWxsZXRBZGRyZXNzLnRvTG93
ZXJDYXNlKCl9LCAke2Zyb21DdXJyZW5jeX0sICR7dG9DdXJyZW5jeX0sCiAgICAgICAgICAgICAk
e2Zyb21BbW91bnR9LCAke3RvQW1vdW50fSwgJHtzcHJlYWRGZWUgPz8gMH0sICR7bmV0d29ya0Zl
ZSA/PyAwLjAwMX0sCiAgICAgICAgICAgICAke2FyY1R4SGFzaCA/PyBudWxsfSwgJHttZW1vSWQg
Pz8gbnVsbH0sICR7cmVmZXJlbmNlID8/IG51bGx9LAogICAgICAgICAgICAgJHtjb3JyaWRvcklk
ID8/IG51bGx9LCAke2NvcnJpZG9yU3RlcCA/PyBudWxsfSwgJHtmcm9tQ2hhaW4gPz8gbnVsbH0s
ICdwZW5kaW5nJywgJHtub3d9KWAKICAgICAgKQogICAgfSBlbHNlIHsKICAgICAgYXdhaXQgZGIu
cnVuKAogICAgICAgIHNxbGBJTlNFUlQgT1IgSUdOT1JFIElOVE8gdHJhbnNhY3Rpb25zCiAgICAg
ICAgICAgIChpZCwgd2FsbGV0X2FkZHJlc3MsIGZyb21fY3VycmVuY3ksIHRvX2N1cnJlbmN5LAog
ICAgICAgICAgICAgZnJvbV9hbW91bnQsIHRvX2Ftb3VudCwgc3ByZWFkX2ZlZSwgbmV0d29ya19m
ZWUsCiAgICAgICAgICAgICBhcmNfdHhfaGFzaCwgbWVtb19pZCwgcmVmZXJlbmNlLAogICAgICAg
ICAgICAgY29ycmlkb3JfaWQsIGNvcnJpZG9yX3N0ZXAsIHN0YXR1cywgY3JlYXRlZF9hdCkKICAg
ICAgICAgICAgVkFMVUVTCiAgICAgICAgICAgICgke2lkfSwgJHt3YWxsZXRBZGRyZXNzLnRvTG93
ZXJDYXNlKCl9LCAke2Zyb21DdXJyZW5jeX0sICR7dG9DdXJyZW5jeX0sCiAgICAgICAgICAgICAk
e2Zyb21BbW91bnR9LCAke3RvQW1vdW50fSwgJHtzcHJlYWRGZWUgPz8gMH0sICR7bmV0d29ya0Zl
ZSA/PyAwLjAwMX0sCiAgICAgICAgICAgICAke2FyY1R4SGFzaCA/PyBudWxsfSwgJHttZW1vSWQg
Pz8gbnVsbH0sICR7cmVmZXJlbmNlID8/IG51bGx9LAogICAgICAgICAgICAgJHtjb3JyaWRvcklk
ID8/IG51bGx9LCAke2NvcnJpZG9yU3RlcCA/PyBudWxsfSwgJ3BlbmRpbmcnLCAke25vd30pYAog
ICAgICApCiAgICB9CiAgICByZXMuc3RhdHVzKDIwMSkuanNvbih7IGlkIH0pCiAgfSBjYXRjaCAo
ZXJyOiBhbnkpIHsgcmVzLnN0YXR1cyg1MDApLmpzb24oeyBlcnJvcjogZXJyLm1lc3NhZ2UgfSkg
fQp9KQoKLyoKICBQQVRDSCAvdHJhbnNhY3Rpb25zLzpoYXNoLCB1cGRhdGUgc3RhdHVzIGFmdGVy
IG9uLWNoYWluIGNvbmZpcm1hdGlvbi4KCiAgSU1QT1JUQU5UIERJU1RJTkNUSU9OLiBBIGNvbmZp
cm1lZCBvbi1jaGFpbiB0cmFuc2ZlciBtZWFucyB0aGUgVVNEQyBsZWZ0IHRoZQogIHVzZXIncyB3
YWxsZXQuIEZvciBhIFVTREMgdG8gZmlhdCBjb252ZXJzaW9uIHRoYXQgaXMgTk9UIHRoZSBzYW1l
IGFzIHRoZQogIGNvbnZlcnNpb24gYmVpbmcgU0VUVExFRDogc2V0dGxlZCBzaG91bGQgbWVhbiB0
aGUgcmVjaXBpZW50IGFjdHVhbGx5IHJlY2VpdmVkCiAgdGhlaXIgbW9uZXksIHdoaWNoIGhhcHBl
bnMgbGF0ZXIsIHZpYSBhIHBheW91dCBwcm92aWRlci4KCiAgQ2FsbGluZyB0aGF0ICdzZXR0bGVk
JyB0b2xkIHVzZXJzIHRoZWlyIG1vbmV5IGhhZCBhcnJpdmVkIHdoZW4gaXQgaGFkIG5vdC4KICBT
byBhbiBvbi1jaGFpbiBjb25maXJtYXRpb24gbm93IHJlY29yZHMgJ2Z1bmRlZCcgZm9yIGZpYXQt
Ym91bmQgY29udmVyc2lvbnMsCiAgYW5kIG9ubHkgdGhlIHBheW91dCBjb21wbGV0aW5nIG1hcmtz
IHRoZW0gJ3NldHRsZWQnLiBDYWxsZXJzIGNhbiBzdGlsbCBwYXNzIGFuCiAgZXhwbGljaXQgc3Rh
dHVzIGZvciBvdGhlciBjYXNlcy4KKi8Kcm91dGVyLnBhdGNoKCcvOmhhc2gnLCBhc3luYyAocmVx
LCByZXMpID0+IHsKICBjb25zdCB7IHN0YXR1cyB9ID0gcmVxLmJvZHkKICBjb25zdCBub3cgICAg
ICAgID0gTWF0aC5mbG9vcihEYXRlLm5vdygpIC8gMTAwMCkKICB0cnkgewogICAgYXdhaXQgZGIu
cnVuKAogICAgICBzcWxgVVBEQVRFIHRyYW5zYWN0aW9ucwogICAgICAgICAgU0VUIHN0YXR1cyAg
ICAgPSAke3N0YXR1cyA/PyAnZnVuZGVkJ30sCiAgICAgICAgICAgICAgc2V0dGxlZF9hdCA9ICR7
c3RhdHVzID09PSAnc2V0dGxlZCcgPyBub3cgOiBudWxsfQogICAgICAgICAgV0hFUkUgYXJjX3R4
X2hhc2ggPSAke3JlcS5wYXJhbXMuaGFzaH0KICAgICAgICAgICAgIE9SIGlkICAgICAgICAgID0g
JHtyZXEucGFyYW1zLmhhc2h9YAogICAgKQogICAgcmVzLmpzb24oeyBzdWNjZXNzOiB0cnVlIH0p
CiAgfSBjYXRjaCAoZXJyOiBhbnkpIHsgcmVzLnN0YXR1cyg1MDApLmpzb24oeyBlcnJvcjogZXJy
Lm1lc3NhZ2UgfSkgfQp9KQoKLy8gR0VUIC90cmFuc2FjdGlvbnMvcmVmLzpyZWYKcm91dGVyLmdl
dCgnL3JlZi86cmVmJywgYXN5bmMgKHJlcSwgcmVzKSA9PiB7CiAgdHJ5IHsKICAgIGNvbnN0IHJv
d3MgPSBhd2FpdCBkYi5ydW4oCiAgICAgIHNxbGBTRUxFQ1QgKiBGUk9NIHRyYW5zYWN0aW9ucyBX
SEVSRSByZWZlcmVuY2UgPSAke3JlcS5wYXJhbXMucmVmfSBMSU1JVCAxYAogICAgKQogICAgY29u
c3QgciA9IHBhcnNlUm93cyhyb3dzKQogICAgaWYgKCFyLmxlbmd0aCkgcmV0dXJuIHJlcy5zdGF0
dXMoNDA0KS5qc29uKHsgZXJyb3I6ICdOb3QgZm91bmQnIH0pCiAgICByZXMuanNvbihyWzBdKQog
IH0gY2F0Y2ggKGVycjogYW55KSB7IHJlcy5zdGF0dXMoNTAwKS5qc29uKHsgZXJyb3I6IGVyci5t
ZXNzYWdlIH0pIH0KfSkKCmV4cG9ydCBkZWZhdWx0IHJvdXRlcgo=
B64_FX2TR
decode_verify "$WORK/FX2TR.b64" "$WORK/FX2TR.out" "$M_TR" "transactions.ts"
place_edit "$WORK/FX2TR.out" "$F_TR"

# ---- FX2MIG ----
cat > "$WORK/FX2MIG.b64" <<'B64_FX2MIG'
LS0gPT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
PT09PT09Ci0tIDAwMjNfdHJhbnNhY3Rpb25zX2Zyb21fY2hhaW5fcmVwYWlyLnNxbAotLSBSZXBh
aXI6IDAwMjIgd2FzIHJlY29yZGVkIGFzIGFwcGxpZWQgb24gdGhlIHByb2R1Y3Rpb24gREIgYnV0
IHRoZQotLSBmcm9tX2NoYWluIGNvbHVtbiBpcyBOT1QgcHJlc2VudCAoUE9TVCAvdHJhbnNhY3Rp
b25zIGZhaWxlZCB3aXRoCi0tICJ0YWJsZSB0cmFuc2FjdGlvbnMgaGFzIG5vIGNvbHVtbiBuYW1l
ZCBmcm9tX2NoYWluIikuIFRoaXMgcmUtYWRkcyBpdC4KLS0KLS0gU2FmZSB0byBydW4gd2hldGhl
ciBvciBub3QgdGhlIGNvbHVtbiBleGlzdHM6IGlmIGl0IGlzIGFscmVhZHkgcHJlc2VudCB0aGUK
LS0gbWlncmF0ZSBydW5uZXIgdHJlYXRzIHRoZSAiZHVwbGljYXRlIGNvbHVtbiBuYW1lIiBlcnJv
ciBhcyBhbHJlYWR5LWFwcGxpZWQKLS0gYW5kIHNraXBzIGl0LiBJZiAwMDIyIGdlbnVpbmVseSBu
ZXZlciByYW4sIHRoaXMgYWRkcyB0aGUgY29sdW1uIGZvciByZWFsLgotLSBOVUxMID0gQXJjICho
aXN0b3JpY2FsIGRlZmF1bHQpLCBzbyBleGlzdGluZyByb3dzIGFyZSB1bmFmZmVjdGVkLgotLSA9
PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
PT0KCkFMVEVSIFRBQkxFIHRyYW5zYWN0aW9ucyBBREQgQ09MVU1OIGZyb21fY2hhaW4gVEVYVDsK
B64_FX2MIG
decode_verify "$WORK/FX2MIG.b64" "$WORK/FX2MIG.out" "$M_MIG" "0023 migration"
place_new "$WORK/FX2MIG.out" "$F_MIG"

echo ""
echo "✓ Repair applied."
echo "  EDIT $F_TR"
echo "  NEW  $F_MIG"
echo "  backup → $BACKUP_DIR (revert: bash $0 --revert)"
echo ""
echo "Deploy:"
echo "  cd \"$API_DIR\" && npx tsc --noEmit && npm run build"
echo "  git add -A && git commit -m \"fix: repair transactions.from_chain (0022 didnt apply) + resilient insert\" && git push"
echo ""
echo "Sends record again the moment this deploys (even before 0023 runs). After"
echo "0023 applies on Render, cross-chain sends also settle + link to the right"
echo "explorer. VERIFY after deploy:"
echo "  curl -sS -X POST https://afrifx-api.onrender.com/transactions -H 'Content-Type: application/json' \\"
echo "    -d '{\"walletAddress\":\"0x0000000000000000000000000000000000000001\",\"fromCurrency\":\"USDC\",\"toCurrency\":\"USDC\",\"fromAmount\":0.01,\"toAmount\":0.01,\"arcTxHash\":\"0xdiag2\",\"fromChain\":\"base\"}'"
echo "  → expect {\"id\":\"0xdiag2\"} (not the from_chain error)."
