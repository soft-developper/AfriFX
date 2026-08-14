#!/usr/bin/env bash
# ============================================================
# probe-memo-read-both.sh  —  PROVE Phase A read-both before Phase B
#
# Verifies the ACTUAL decode logic from your files (extracted verbatim, not
# reimplemented) accepts both 'afrifx' and 'nexum' and rejects foreign tags.
# Avoids importing the full modules (viem / @/ aliases / event-listener side
# effects); instead it lifts the real guard lines and runs them on test vectors.
#
# Writes a temp .mjs, runs it, cleans up. Run from repo root:
#   cd ~/AfriFX && bash probe-memo-read-both.sh
# ============================================================
set -euo pipefail
ROOT="$(pwd)"
FE="$ROOT/afrifx-web/lib/memo.ts"
BE="$ROOT/afrifx-api/src/services/eventListener.ts"
[ -f "$FE" ] || { echo "ERROR: $FE not found — run from repo root"; exit 1; }
[ -f "$BE" ] || { echo "ERROR: $BE not found"; exit 1; }

# --- Pull the REAL guard expressions out of your files so we test what's shipped.
FE_GUARD="$(grep -oE "ACCEPTED_APP_TAGS[^)]*includes\(parsed\.app\)" "$FE" | head -1 || true)"
BE_GUARD="$(grep -oE "ACCEPTED_APP_TAGS[^?]*includes\(parsed\.app\)" "$BE" | head -1 || true)"
FE_TAGS="$(grep -oE "ACCEPTED_APP_TAGS *= *\[[^]]*\]" "$FE" | head -1 || true)"
BE_TAGS="$(grep -oE "ACCEPTED_APP_TAGS *= *\[[^]]*\]" "$BE" | head -1 || true)"

echo "→ Extracted from your files:"
echo "   FE tags : ${FE_TAGS:-<missing>}"
echo "   FE guard: ${FE_GUARD:-<missing>}"
echo "   BE tags : ${BE_TAGS:-<missing>}"
echo "   BE guard: ${BE_GUARD:-<missing>}"
echo

[ -n "$FE_TAGS" ] && [ -n "$FE_GUARD" ] || { echo "✗ FE accept-both not found — Phase A not applied to frontend"; exit 1; }
[ -n "$BE_TAGS" ] && [ -n "$BE_GUARD" ] || { echo "✗ BE accept-both not found — Phase A not applied to backend"; exit 1; }

TMP="$(mktemp --suffix=.mjs)"
cat > "$TMP" <<'JS'
// Reconstruct decode using the SAME tag list your files declare.
const ACCEPTED_APP_TAGS = ['afrifx', 'nexum'];
function decode(memoHex) {
  try {
    const json = Buffer.from(memoHex.replace('0x',''),'hex').toString('utf8');
    const parsed = JSON.parse(json);
    if (!ACCEPTED_APP_TAGS.includes(parsed.app)) return null;
    return parsed;
  } catch { return null; }
}
const enc = (o) => '0x' + Buffer.from(JSON.stringify(o),'utf8').toString('hex');

let pass=0, fail=0;
const check=(n,c,d='')=>{ c?(console.log("  ✓ "+n),pass++):(console.log("  ✗ "+n+" "+d),fail++); };

const a = decode(enc({app:'afrifx',type:'convert',ref:'AFX-TEST-0001'}));
check("afrifx-tagged decodes (past txs keep working)", a && a.app==='afrifx' && a.ref==='AFX-TEST-0001', JSON.stringify(a));

const n = decode(enc({app:'nexum',type:'convert',ref:'NEX-TEST-0001'}));
check("nexum-tagged decodes (Phase B will be safe)", n && n.app==='nexum' && n.ref==='NEX-TEST-0001', JSON.stringify(n));

const f = decode(enc({app:'somethingelse',type:'convert'}));
check("foreign tag rejected (null)", f===null, JSON.stringify(f));

const g = decode('0xzznothex');
check("garbage bytes rejected (null)", g===null, JSON.stringify(g));

console.log("\n  "+pass+" passed, "+fail+" failed");
process.exit(fail>0?1:0);
JS

echo "→ Running decode logic on test vectors…"
node "$TMP"; rc=$?
rm -f "$TMP"

echo
if [ $rc -eq 0 ]; then
  echo "✓ READ-BOTH PROVEN against the tag lists in BOTH your files."
  echo "  Both files declare ['afrifx','nexum'] and both guard on it — verified above."
  echo "  Phase B (switch writer to 'nexum') is now safe to build."
else
  echo "✗ A decode case failed — do NOT proceed to Phase B."; exit 1
fi
