#!/usr/bin/env bash
# ============================================================================
# ramp-fix-customers-endorsements.sh
#
# CORRECTIVE PATCH. Phase 2b applied only partially on this machine: routes/
# ramp.ts got the endorsements route (it imports getCustomerEndorsements +
# ENDORSEMENT_CURRENCY), but services/bridgexyz/customers.ts never received
# those exports — so `tsc` fails with TS2305 "has no exported member".
#
# This restores customers.ts to the correct Phase-2b version, which is a strict
# SUPERSET of the original — it only ADDS the endorsements block (getCustomer,
# getCustomerEndorsements, ENDORSEMENT_CURRENCY, the Bridge* types). Nothing
# else in the file changes. After this, tsc + build pass and the endorsement-
# gated currency grid works as designed.
#
# Safe: whole-file replace with a backup + --revert, idempotent (marker guard),
# and it verifies the new file still contains the original's KYC exports before
# placing, so it can't strip anything you rely on.
#
# Usage:
#   bash ramp-fix-customers-endorsements.sh           # apply
#   bash ramp-fix-customers-endorsements.sh --revert  # restore
# ============================================================================
set -euo pipefail

find_api_dir() {
  for d in "nexum-api" "afrifx-api" "." "../nexum-api" "../afrifx-api"; do
    if [ -f "$d/package.json" ] && [ -d "$d/src/services/bridgexyz" ]; then
      (cd "$d" && pwd); return 0
    fi
  done
  return 1
}
API_DIR="$(find_api_dir || true)"
if [ -z "${API_DIR:-}" ]; then echo "✗ Could not find the API package." >&2; exit 1; fi
echo "• API package: $API_DIR"

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$API_DIR/.ramp-fix-customers-backup"
F_CUST="src/services/bridgexyz/customers.ts"
MARKER="getCustomerEndorsements"

if [ "${1:-}" = "--revert" ]; then
  if [ ! -d "$BACKUP_DIR" ]; then echo "✗ No backups." >&2; exit 1; fi
  LATEST="$(ls -1 "$BACKUP_DIR" | sed -n 's/^manifest-\(.*\)\.txt$/\1/p' | sort | tail -1 || true)"
  if [ -z "${LATEST:-}" ]; then echo "✗ No manifest." >&2; exit 1; fi
  bak="$BACKUP_DIR/${F_CUST//\//__}.$LATEST.bak"
  if [ -f "$bak" ]; then cp -f "$bak" "$API_DIR/$F_CUST"; echo "  ↺ restored $F_CUST"; else echo "✗ missing backup" >&2; exit 1; fi
  echo "✓ Revert complete."; exit 0
fi

if [ -f "$API_DIR/$F_CUST" ] && grep -qF "$MARKER" "$API_DIR/$F_CUST"; then
  echo "✓ customers.ts already has the endorsements exports. Nothing to do."; exit 0
fi

mkdir -p "$BACKUP_DIR"
MANIFEST="$BACKUP_DIR/manifest-$STAMP.txt"; : > "$MANIFEST"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

echo "• Restoring customers.ts (Phase 2b version) …"

# ---- FIXCUST ----
cat > "$WORK/FIXCUST.b64" <<'B64_FIXCUST'
Ly8gPT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
PT09PT09Ci8vIEJyaWRnZS54eXogY3VzdG9tZXIgKyBLWUMtbGluayBvcGVyYXRpb25zIChQaGFz
ZSAxKS4KLy8KLy8gV2UgdXNlIEJyaWRnZSdzIEhPU1RFRCBvbmJvYXJkaW5nIChLWUMgTGlua3Mg
LyBQZXJzb25hKSDigJQgTk9UIGRpcmVjdCBBUEkKLy8gY3VzdG9tZXIgY3JlYXRpb24g4oCUIHNv
IE5leHVtIG5ldmVyIGNvbGxlY3RzIG9yIHRyYW5zbWl0cyBTU05zIG9yIElELWRvY3VtZW50Ci8v
IGltYWdlcy4gV2UgY2FsbCBQT1NUIC92MC9reWNfbGlua3MgdG8gZ2V0IGEgUGVyc29uYSBreWNf
bGluayArIGEgQnJpZGdlCi8vIHRvc19saW5rLCBoYW5kIHRob3NlIHRvIHRoZSB1c2VyLCBhbmQg
cG9sbCBHRVQgL3YwL2t5Y19saW5rcy86aWQgZm9yIHN0YXR1cy4KLy8gPT09PT09PT09PT09PT09
PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09CgppbXBvcnQgeyBi
cmlkZ2VGZXRjaCB9IGZyb20gJy4vY2xpZW50JwoKZXhwb3J0IHR5cGUgQnJpZGdlS3ljU3RhdHVz
ID0KICB8ICdub3Rfc3RhcnRlZCcgfCAndW5kZXJfcmV2aWV3JyB8ICdpbmNvbXBsZXRlJwogIHwg
J2F3YWl0aW5nX3F1ZXN0aW9ubmFpcmUnIHwgJ2F3YWl0aW5nX3VibycKICB8ICdhcHByb3ZlZCcg
fCAncmVqZWN0ZWQnIHwgJ3BhdXNlZCcgfCAnb2ZmYm9hcmRlZCcKCmV4cG9ydCB0eXBlIEJyaWRn
ZVRvc1N0YXR1cyA9ICdwZW5kaW5nJyB8ICdhcHByb3ZlZCcKCmV4cG9ydCB0eXBlIEJyaWRnZUN1
c3RvbWVyVHlwZSA9ICdpbmRpdmlkdWFsJyB8ICdidXNpbmVzcycKCmV4cG9ydCBpbnRlcmZhY2Ug
QnJpZGdlUmVqZWN0aW9uUmVhc29uIHsKICBkZXZlbG9wZXJfcmVhc29uPzogc3RyaW5nCiAgcmVh
c29uPzogc3RyaW5nCiAgY3JlYXRlZF9hdD86IHN0cmluZwp9CgpleHBvcnQgaW50ZXJmYWNlIEt5
Y0xpbmtSZXNwb25zZSB7CiAgaWQ6ICAgICAgICAgICAgICAgIHN0cmluZwogIGZ1bGxfbmFtZTog
ICAgICAgICBzdHJpbmcKICBlbWFpbDogICAgICAgICAgICAgc3RyaW5nCiAgdHlwZTogICAgICAg
ICAgICAgIEJyaWRnZUN1c3RvbWVyVHlwZQogIGt5Y19saW5rOiAgICAgICAgICBzdHJpbmcKICB0
b3NfbGluazogICAgICAgICAgc3RyaW5nCiAga3ljX3N0YXR1czogICAgICAgIEJyaWRnZUt5Y1N0
YXR1cwogIHRvc19zdGF0dXM6ICAgICAgICBCcmlkZ2VUb3NTdGF0dXMKICByZWplY3Rpb25fcmVh
c29uczogQnJpZGdlUmVqZWN0aW9uUmVhc29uW10KICBjdXN0b21lcl9pZDogICAgICAgc3RyaW5n
IHwgbnVsbAogIGNyZWF0ZWRfYXQ/OiAgICAgICBzdHJpbmcKfQoKLyoqCiAqIENyZWF0ZSBhIGhv
c3RlZCBLWUMgbGluayBmb3IgYSBuZXcgY3VzdG9tZXIuIEJyaWRnZSByZXR1cm5zIGEgUGVyc29u
YQogKiBreWNfbGluayArIGEgVG9TIGxpbmsuIGBpZGVtcG90ZW5jeUtleWAgc2hvdWxkIGJlIHN0
YWJsZSBwZXIgYWNjb3VudCBzbyBhCiAqIHJldHJ5IGRvZXNuJ3QgY3JlYXRlIGEgc2Vjb25kIGxp
bmsuCiAqLwpleHBvcnQgYXN5bmMgZnVuY3Rpb24gY3JlYXRlS3ljTGluayhwYXJhbXM6IHsKICBm
dWxsTmFtZTogc3RyaW5nCiAgZW1haWw6ICAgIHN0cmluZwogIHR5cGU6ICAgICBCcmlkZ2VDdXN0
b21lclR5cGUKICBpZGVtcG90ZW5jeUtleTogc3RyaW5nCn0pOiBQcm9taXNlPEt5Y0xpbmtSZXNw
b25zZT4gewogIHJldHVybiBicmlkZ2VGZXRjaDxLeWNMaW5rUmVzcG9uc2U+KCdreWNfbGlua3Mn
LCB7CiAgICBtZXRob2Q6ICdQT1NUJywKICAgIGlkZW1wb3RlbmN5S2V5OiBwYXJhbXMuaWRlbXBv
dGVuY3lLZXksCiAgICBib2R5OiB7CiAgICAgIGZ1bGxfbmFtZTogcGFyYW1zLmZ1bGxOYW1lLAog
ICAgICBlbWFpbDogICAgIHBhcmFtcy5lbWFpbCwKICAgICAgdHlwZTogICAgICBwYXJhbXMudHlw
ZSwKICAgIH0sCiAgfSkKfQoKLyoqIFBvbGwgdGhlIGN1cnJlbnQgc3RhdHVzIG9mIGEgS1lDIGxp
bmsuICovCmV4cG9ydCBhc3luYyBmdW5jdGlvbiBnZXRLeWNMaW5rKGt5Y0xpbmtJZDogc3RyaW5n
KTogUHJvbWlzZTxLeWNMaW5rUmVzcG9uc2U+IHsKICByZXR1cm4gYnJpZGdlRmV0Y2g8S3ljTGlu
a1Jlc3BvbnNlPihga3ljX2xpbmtzLyR7a3ljTGlua0lkfWAsIHsgbWV0aG9kOiAnR0VUJyB9KQp9
CgovKioKICogU0FOREJPWCBPTkxZIOKAlCBmb3JjZSBhIGN1c3RvbWVyIHRvIEtZQy1hcHByb3Zl
ZCBzbyB0aGUgZmxvdyBjYW4gYmUgdGVzdGVkCiAqIGVuZC10by1lbmQgd2l0aG91dCBkb2luZyBh
IHJlYWwgUGVyc29uYSB2ZXJpZmljYXRpb24uIE5vLW9wIHNpZ25hdHVyZSBpbgogKiBwcm9kdWN0
aW9uIChCcmlkZ2UgcmVqZWN0cyBpdCksIHNvIGNhbGxlcnMgbXVzdCBnYXRlIG9uIHNhbmRib3gu
CiAqLwpleHBvcnQgYXN5bmMgZnVuY3Rpb24gc2ltdWxhdGVLeWNBcHByb3ZhbChjdXN0b21lcklk
OiBzdHJpbmcsIGlkZW1wb3RlbmN5S2V5OiBzdHJpbmcpOiBQcm9taXNlPHVua25vd24+IHsKICBy
ZXR1cm4gYnJpZGdlRmV0Y2goYGN1c3RvbWVycy8ke2N1c3RvbWVySWR9L3NpbXVsYXRlX2t5Y19h
cHByb3ZhbGAsIHsKICAgIG1ldGhvZDogJ1BPU1QnLAogICAgaWRlbXBvdGVuY3lLZXksCiAgfSkK
fQoKLy8g4pSA4pSAIEVuZG9yc2VtZW50cyDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDi
lIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDi
lIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDi
lIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIAKLy8gQSBjdXN0b21lciBpcyBvbmx5
IGFsbG93ZWQgdG8gdHJhbnNhY3Qgb24gYSBjdXJyZW5jeSdzIHJhaWwgd2hlbiB0aGUgbWF0Y2hp
bmcKLy8gZW5kb3JzZW1lbnQgaXMgYXBwcm92ZWQuIEVuZG9yc2VtZW50cyBsaXZlIG9uIHRoZSBD
VVNUT01FUiBvYmplY3QgKG5vdCB0aGUKLy8gS1lDIGxpbmspLCBzbyB3ZSByZWFkIHRoZW0gZnJv
bSBHRVQgL3YwL2N1c3RvbWVycy97aWR9LgoKZXhwb3J0IHR5cGUgQnJpZGdlRW5kb3JzZW1lbnRO
YW1lID0KICB8ICdiYXNlJyB8ICdzZXBhJyB8ICdzcGVpJyB8ICdwaXgnIHwgJ2Zhc3Rlcl9wYXlt
ZW50cycgfCAnY29wJyB8IHN0cmluZwoKZXhwb3J0IGludGVyZmFjZSBCcmlkZ2VFbmRvcnNlbWVu
dCB7CiAgbmFtZTogICAgQnJpZGdlRW5kb3JzZW1lbnROYW1lCiAgc3RhdHVzOiAgc3RyaW5nICAg
Ly8gJ2FwcHJvdmVkJyB8ICdpbmNvbXBsZXRlJyB8IOKApgogIHJlcXVpcmVtZW50cz86IHVua25v
d24KICBmdXR1cmVfcmVxdWlyZW1lbnRzPzogdW5rbm93bgp9CgpleHBvcnQgaW50ZXJmYWNlIEJy
aWRnZUN1c3RvbWVyT2JqZWN0IHsKICBpZDogICAgICAgICAgICBzdHJpbmcKICBlbmRvcnNlbWVu
dHM/OiBCcmlkZ2VFbmRvcnNlbWVudFtdCiAgW2tleTogc3RyaW5nXTogdW5rbm93bgp9CgovKiog
RmV0Y2ggdGhlIGZ1bGwgY3VzdG9tZXIgb2JqZWN0IChmb3IgaXRzIGVuZG9yc2VtZW50cyBhcnJh
eSkuICovCmV4cG9ydCBhc3luYyBmdW5jdGlvbiBnZXRDdXN0b21lcihjdXN0b21lcklkOiBzdHJp
bmcpOiBQcm9taXNlPEJyaWRnZUN1c3RvbWVyT2JqZWN0PiB7CiAgcmV0dXJuIGJyaWRnZUZldGNo
PEJyaWRnZUN1c3RvbWVyT2JqZWN0PihgY3VzdG9tZXJzLyR7Y3VzdG9tZXJJZH1gLCB7IG1ldGhv
ZDogJ0dFVCcgfSkKfQoKLyoqIEp1c3QgdGhlIGVuZG9yc2VtZW50cyBhcnJheSAoZW1wdHkgaWYg
bm9uZSkuICovCmV4cG9ydCBhc3luYyBmdW5jdGlvbiBnZXRDdXN0b21lckVuZG9yc2VtZW50cyhj
dXN0b21lcklkOiBzdHJpbmcpOiBQcm9taXNlPEJyaWRnZUVuZG9yc2VtZW50W10+IHsKICBjb25z
dCBjID0gYXdhaXQgZ2V0Q3VzdG9tZXIoY3VzdG9tZXJJZCkKICByZXR1cm4gQXJyYXkuaXNBcnJh
eShjLmVuZG9yc2VtZW50cykgPyBjLmVuZG9yc2VtZW50cyA6IFtdCn0KCi8qKgogKiBXaGljaCBm
aWF0IGN1cnJlbmN5IGVhY2ggZW5kb3JzZW1lbnQgdW5sb2Nrcy4gVVNEIGlzIHRoZSBgYmFzZWAg
ZW5kb3JzZW1lbnQ7CiAqIHRoZSByZXN0IG1hcCBvbmUtdG8tb25lLiBDdXJyZW5jaWVzIGFyZSBs
b3dlci1jYXNlIHRvIG1hdGNoIG91ciBjb3JyaWRvciByb3dzLgogKi8KZXhwb3J0IGNvbnN0IEVO
RE9SU0VNRU5UX0NVUlJFTkNZOiBSZWNvcmQ8c3RyaW5nLCBzdHJpbmc+ID0gewogIGJhc2U6ICAg
ICAgICAgICAgJ3VzZCcsCiAgc2VwYTogICAgICAgICAgICAnZXVyJywKICBzcGVpOiAgICAgICAg
ICAgICdteG4nLAogIHBpeDogICAgICAgICAgICAgJ2JybCcsCiAgZmFzdGVyX3BheW1lbnRzOiAn
Z2JwJywKICBjb3A6ICAgICAgICAgICAgICdjb3AnLAp9Cg==
B64_FIXCUST

# Decode + verify.
if ! base64 --decode "$WORK/FIXCUST.b64" > "$WORK/FIXCUST.out" 2>/dev/null; then
  echo "✗ decode failed — nothing written." >&2; exit 1; fi
if [ ! -s "$WORK/FIXCUST.out" ]; then echo "✗ decoded empty — aborting." >&2; exit 1; fi
# Must contain the NEW exports AND preserve the original KYC exports.
for needle in "getCustomerEndorsements" "ENDORSEMENT_CURRENCY" "createKycLink" "getKycLink" "simulateKycApproval"; do
  if ! grep -qF "$needle" "$WORK/FIXCUST.out"; then
    echo "✗ safety check failed: new file missing '$needle' — aborting, nothing written." >&2; exit 1
  fi
done
# Back up the current file and place the new one.
if [ ! -f "$API_DIR/$F_CUST" ]; then echo "✗ Missing $F_CUST" >&2; exit 1; fi
cp -f "$API_DIR/$F_CUST" "$BACKUP_DIR/${F_CUST//\//__}.$STAMP.bak"
echo "EDIT|$F_CUST" >> "$MANIFEST"
cp -f "$WORK/FIXCUST.out" "$API_DIR/$F_CUST"
echo "  ~ restored $F_CUST (backup saved)"
echo ""
echo "✓ Fix applied."
echo "  EDIT $F_CUST  (backup → $BACKUP_DIR; revert: bash $0 --revert)"
echo ""
echo "Now:"
echo "  cd \"$API_DIR\" && npx tsc --noEmit && npm run build"
echo "  (then commit + push the Part 2 change together with this fix)"
echo ""
echo "This also makes the endorsement-gated currency grid work — the part of"
echo "Phase 2b that never fully landed on this machine."
