#!/usr/bin/env bash
# ============================================================
# rename-step8-css-and-residual.sh — AfriFX→Nexum, STEP 8: CSS classes + residual copy
#
# PURELY COSMETIC — no deploy/data risk.
#   A) Rename CSS classes/id  afx-* → nx-*  (definitions in globals.css AND all
#      usages in components, in lockstep).  afx-gradient-text, afx-gradient-text-bright,
#      afx-scroll, afx-mark-g.
#   B) Sweep any residual user-visible 'AfriFX' display strings that Step 1 missed
#      (e.g. /about,/contact metadata titles, some admin pages), → 'Nexum'.
#      Idempotent: strings already fixed in Step 1 simply won't match.
#
# EXCLUDED (same structural guard as Step 1 — never touched):
#   AfriFXLogo, AfriFXMemoPayload, afrifx_/AFRIFX_ keys, memo tag app:'afrifx',
#   afrifx.* URLs, afrifx-settlements filename, x.com/afrifx handle.
#
# Run from repo root:  cd ~/AfriFX && bash rename-step8-css-and-residual.sh
# ============================================================
set -euo pipefail
ROOT="$(pwd)"; WEB="$ROOT/nexum-web"
[ -d "$WEB" ] || { echo "ERROR: run from repo root (nexum-web not found)"; exit 1; }
cd "$WEB"

CSS="styles/globals.css"
[ -f "$CSS" ] || { echo "ERROR: $CSS not found"; exit 1; }

echo "→ 1/2  Renaming CSS classes afx-* → nx-* (definitions + usages)…"
# Collect every file that uses afx- (components/pages) plus the stylesheet.
mapfile -t CSSFILES < <(grep -rlE "afx-(gradient-text-bright|gradient-text|scroll|mark-g)" --include=*.tsx --include=*.ts --include=*.css . 2>/dev/null | grep -vE "node_modules|\.next")
if [ ${#CSSFILES[@]} -eq 0 ]; then
  echo "  • no afx- classes found (already renamed?)"
else
  for f in "${CSSFILES[@]}"; do
    # order: longest first so -bright isn't half-matched by -text
    perl -0pi -e "s/afx-gradient-text-bright/nx-gradient-text-bright/g;
                  s/afx-gradient-text/nx-gradient-text/g;
                  s/afx-scroll/nx-scroll/g;
                  s/afx-mark-g/nx-mark-g/g;" "$f"
    echo "  ✓ $(echo "$f" | sed 's#^\./##')"
  done
fi
# verify none remain
LEFT_CSS=$(grep -rnE "afx-(gradient-text|scroll|mark-g)" --include=*.tsx --include=*.ts --include=*.css . 2>/dev/null | grep -vE "node_modules|\.next" || true)
[ -z "$LEFT_CSS" ] && echo "  ✓ no afx- classes remain" || { echo "  ✗ leftover afx-:"; echo "$LEFT_CSS"; exit 1; }

echo "→ 2/2  Sweeping residual visible 'AfriFX' display strings (structural lines skipped)…"
PL="$(mktemp --suffix=.pl)"
cat > "$PL" <<'PERL'
# Same structural guard as Step 1 — never edit these lines.
my $guard = qr/afrifx_|AFRIFX_|AfriFXLogo|AfriFXMemoPayload|afx-|nx-|afrifx\.(?:xyz|com|vercel|onrender|network|app)|x\.com\/afrifx|app:\s*'(?:afrifx|nexum)'|parsed\.app|afrifx-settlements|nexumpay/;
while (my $line = <>) {
  if ($line =~ $guard) { print $line; next; }
  $line =~ s/\bAfriFX\b/Nexum/g;
  print $line;
}
PERL
mapfile -t FILES < <(grep -rlE "\bAfriFX\b" --include=*.tsx --include=*.ts app components lib hooks 2>/dev/null | grep -vE "node_modules|\.next")
CNT=0
for f in "${FILES[@]}"; do
  # skip the brand component file (contains AfriFXLogo identifier + is guarded anyway)
  perl "$PL" "$f" > "$f.tmp" && mv "$f.tmp" "$f"
  CNT=$((CNT+1))
done
rm -f "$PL"
echo "  ✓ swept $CNT file(s) containing AfriFX"

echo
echo "→ Verify: residual display AfriFX (excluding structural) — should be empty:"
GUARD='afrifx_|AFRIFX_|AfriFXLogo|AfriFXMemoPayload|afx-|nx-|afrifx\.(xyz|com|vercel|onrender|network|app)|x.com/afrifx|app: .(afrifx|nexum).|parsed.app|afrifx-settlements|nexumpay'
grep -rnE "\bAfriFX\b" --include=*.tsx --include=*.ts app components lib hooks 2>/dev/null | grep -vE "node_modules|\.next" | grep -vE "$GUARD" || echo "  ✓ none"
echo
echo "→ Structural AfriFX* identifiers intentionally KEPT (sanity):"
grep -rn "AfriFXLogo\|AfriFXMemoPayload" --include=*.tsx --include=*.ts . 2>/dev/null | grep -vE "node_modules|\.next" | wc -l | sed 's/^/  kept: /'

echo
echo "Done (Step 8, cosmetic). Next:"
echo "  cd nexum-web && rm -rf .next && npx tsc --noEmit && npm run build && cd .."
echo "  git add -A && git commit -m 'rebrand(step8): css classes afx-→nx- + residual display strings' && git push"
