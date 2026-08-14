#!/usr/bin/env bash
# ============================================================
# rename-step1-display-text.sh   —  AfriFX → Nexum, STEP 1 of N
#
# SCOPE: user-VISIBLE display text ONLY. Safest slice of the rename.
#
# EXPLICITLY NOT TOUCHED (later, separately-verified steps):
#   • Code identifiers: AfriFXLogo (component/file), AfriFXMemoPayload (type)
#   • Storage/session keys: afrifx_token, afrifx_account, afrifx_admin*, afrifx_theme
#   • Env keys: NEXT_PUBLIC_AFRIFX_VAULT/_EXCHANGE, CONTRACTS.AFRIFX_*
#   • On-chain memo tag app:'afrifx' and buildMemoId seed `afrifx-...`
#     (changing these breaks decoding of EXISTING on-chain references)
#   • URLs/domains: afrifx.xyz, afrifx.onrender.com, CORS allowlist, email APP_URL
#     (cannot change until nexum.xyz is live + DNS/Render/Vercel updated)
#   • Downloaded filename prefix, social URL placeholders
#
# WHAT IT DOES:
#   1. Logo wordmark "Afri"+"FX" → two-tone "Nex"+"um"; hexagon mark dropped.
#   2. Swaps visible display phrases AfriFX→Nexum, skipping any structural line.
#
# Idempotent. Uses a temp .pl helper (write→run→cleanup) to avoid shell-quoting
# pitfalls. Run from repo root:  cd ~/AfriFX && bash rename-step1-display-text.sh
# ============================================================
set -euo pipefail
ROOT="$(pwd)"; WEB="$ROOT/afrifx-web"
[ -d "$WEB" ] || { echo "ERROR: run from AfriFX repo root"; exit 1; }
cd "$WEB"

LOGO="components/brand/AfriFXLogo.tsx"

echo "→ 1/2  Logo wordmark → two-tone Nex/um, drop hexagon mark…"
if [ -f "$LOGO" ] && grep -q 'afx-gradient-text">Afri' "$LOGO"; then
  perl -0pi -e 's{<span className="afx-gradient-text">Afri</span>\s*<span className="afx-gradient-text-bright">FX</span>}{<span className="afx-gradient-text">Nex</span><span className="afx-gradient-text-bright">um</span>}s' "$LOGO"
  perl -0pi -e 's/showMark = true,/showMark = false, \/\/ NEXUM: hexagon mark dropped pending new design/s' "$LOGO"
  grep -q 'afx-gradient-text">Nex' "$LOGO" && echo "  ✓ wordmark now Nex+um, mark defaulted off" || echo "  ✗ wordmark swap failed"
else
  echo "  • logo already updated or pattern not found (skip)"
fi

echo "→ 2/2  Swapping visible display phrases AfriFX → Nexum (structural lines skipped)…"

# --- temp perl helper: does the guarded replacement on one file ---
PL="$(mktemp --suffix=.pl)"
cat > "$PL" <<'PERL'
# Structural guard: never touch a line matching this.
my $guard = qr/afrifx_|AFRIFX_|AfriFXLogo|AfriFXMemoPayload|afx-|afrifx\.(?:xyz|com|vercel|onrender|network|app)|x\.com\/afrifx|app:\s*'afrifx'|parsed\.app|afrifx-\$\{seed|afrifx-settlements/;

# Specific display phrases first (longest/most specific win), then bare AfriFX.
my @pairs = (
  ["AfriFX, Stablecoin FX & cross-border payments on Arc", "Nexum, Stablecoin FX & cross-border payments on Arc"],
  ["AfriFX, decentralized stablecoin FX and cross-border payments on Arc", "Nexum, decentralized stablecoin FX and cross-border payments on Arc"],
  ["AfriFX, stablecoin FX on Arc", "Nexum, stablecoin FX on Arc"],
  ["AfriFX. Stablecoin FX on Arc.", "Nexum. Stablecoin FX on Arc."],
  ["AfriFX Admin", "Nexum Admin"],
  ["AfriFX wallet", "Nexum wallet"],
  ["AfriFX admin account", "Nexum admin account"],
  ["AfriFX account", "Nexum account"],
  ["AfriFX team", "Nexum team"],
  ["AfriFX backend", "Nexum backend"],
  ["AfriFX user", "Nexum user"],
  ["AfriFX spread", "Nexum spread"],
  ["AfriFX is a decentralized FX and cross-border payments platform", "Nexum is a decentralized FX and cross-border payments platform"],
  ["AfriFX announcements and product updates", "Nexum announcements and product updates"],
  ["Everything in AfriFX", "Everything in Nexum"],
  ["Your message to AfriFX", "Your message to Nexum"],
);

while (my $line = <>) {
  if ($line =~ $guard) { print $line; next; }   # structural — leave untouched
  for my $p (@pairs) { my ($from,$to)=@$p; $line =~ s/\Q$from\E/$to/g; }
  $line =~ s/\bAfriFX\b/Nexum/g;                 # any remaining bare display AfriFX
  print $line;
}
PERL

mapfile -t FILES < <(grep -rlE "AfriFX" --include=*.tsx --include=*.ts components app lib hooks 2>/dev/null | grep -vE "node_modules|\.next")
for f in "${FILES[@]}"; do
  [[ "$f" == "$LOGO" ]] && continue
  perl "$PL" "$f" > "$f.tmp" && mv "$f.tmp" "$f"
done
rm -f "$PL"
echo "  ✓ processed ${#FILES[@]} files"

echo
echo "→ Verifying: any DISPLAY 'AfriFX' left (excluding structural)…"
GUARD='afrifx_|AFRIFX_|AfriFXLogo|AfriFXMemoPayload|afx-|afrifx\.(xyz|com|vercel|onrender|network|app)|x\.com/afrifx|app: .afrifx.|parsed\.app|afrifx-settlements'
LEFT=$(grep -rnE "AfriFX" --include=*.tsx --include=*.ts components app lib hooks 2>/dev/null | grep -vE "node_modules|\.next" | grep -vE "$GUARD" || true)
if [ -z "$LEFT" ]; then echo "  ✓ no display-text AfriFX remaining"; else echo "  ⚠ review:"; echo "$LEFT"; fi

echo
echo "→ Structural 'afrifx' KEPT intentionally (sanity — these SHOULD still exist):"
grep -rnE "app: 'afrifx'|afrifx_token|AFRIFX_VAULT|afrifx\.xyz" --include=*.tsx --include=*.ts components app lib hooks 2>/dev/null | grep -vE "node_modules" | wc -l | sed 's/^/  kept structural hits: /'

echo
echo "Done (Step 1). Next:"
echo "  cd afrifx-web && rm -rf .next && npx tsc --noEmit && npm run build && cd .."
echo "  git add -A && git commit -m 'rebrand(step1): AfriFX -> Nexum visible display text + wordmark' && git push"
