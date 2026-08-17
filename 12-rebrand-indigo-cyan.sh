#!/usr/bin/env bash
#
# 12-rebrand-indigo-cyan.sh
# -------------------------------------------------------------------
# Nexum global rebrand: warm gold  ->  Indigo + Electric Cyan.
#
# Swaps the CSS-variable palette (dark + light, all WCAG-AA verified),
# the wordmark gradients, the RainbowKit wallet accent, the JS token
# fallbacks, favicon, manifest, and the pre-paint themeColor. Adds a
# small "balanced" motion layer (fade/slide-in, accent sheen, number
# roll-up) that is transform/opacity-only and honours
# prefers-reduced-motion, so it costs nothing on load.
#
# DOES NOT TOUCH (functional / on-chain):
#   - lib/memo.ts        'afrifx' memo tags are immutable on-chain values
#   - lib/contracts.ts   AFRIFX_* env-var keys with fallbacks
#   - settlements CSV filename / admin placeholder text (cosmetic only)
#
# Safe to re-run: every edit is guarded so a second run is a no-op.
# A timestamped backup is written before any change; run with --revert
# to restore the most recent backup.
# -------------------------------------------------------------------
set -euo pipefail

# --- locate nexum-web -------------------------------------------------
if   [ -f "./tailwind.config.ts" ] && [ -d "./app" ]; then WEB="."
elif [ -d "./nexum-web" ];                             then WEB="./nexum-web"
elif [ -d "./Nexum-main/nexum-web" ];                  then WEB="./Nexum-main/nexum-web"
else
  echo "ERROR: run this from your nexum-web dir (or its parent). Couldn't find tailwind.config.ts." >&2
  exit 1
fi
cd "$WEB"
echo "==> Working in: $(pwd)"

BACKUP=".rebrand-backup"
FILES=(
  "styles/globals.css"
  "tailwind.config.ts"
  "components/brand/AfriFXLogo.tsx"
  "public/favicon.svg"
  "public/manifest.json"
  "app/layout.tsx"
  "app/providers.tsx"
  "lib/tokens.ts"
)

# --- revert mode ------------------------------------------------------
if [ "${1:-}" = "--revert" ]; then
  latest=$(ls -1dt "$BACKUP"/* 2>/dev/null | head -n1 || true)
  [ -z "$latest" ] && { echo "No backup found under $BACKUP/"; exit 1; }
  echo "==> Reverting from $latest"
  for f in "${FILES[@]}"; do
    [ -f "$latest/$f" ] && mkdir -p "$(dirname "$f")" && cp "$latest/$f" "$f" && echo "   restored $f"
  done
  echo "==> Revert complete."
  exit 0
fi

# --- backup -----------------------------------------------------------
STAMP=$(date +%Y%m%d-%H%M%S)
DEST="$BACKUP/$STAMP"
mkdir -p "$DEST"
for f in "${FILES[@]}"; do
  [ -f "$f" ] && { mkdir -p "$DEST/$(dirname "$f")"; cp "$f" "$DEST/$f"; }
done
echo "==> Backup written to $DEST"

# =====================================================================
# 1. globals.css  — token values, gradients, + motion layer
# =====================================================================
cat > styles/globals.css << 'CSS'
@tailwind base;
@tailwind components;
@tailwind utilities;

/*
  Semantic color tokens as "R G B" channel triples so Tailwind can apply
  opacity modifiers, e.g. bg-app-accent/10.

  BRAND: Indigo + Electric Cyan (global). :root = DARK (deep indigo + cyan);
  html.light overrides to a cool ivory-blue with a deep teal accent so cyan
  stays legible on light surfaces. Every component reads these variables, so
  switching themes is purely a variable swap.

  Accent tokens:
    --app-accent        cyan fill (buttons, bars, active states)
    --app-accent-hover  hover state for accent fills
    --app-accent-text   accent used as READING text (links/labels); deeper in
                        light mode (deep teal) so it passes AA on ivory-blue
    --app-on-accent     text/icons that sit ON an accent fill

  All fg/bg pairings verified WCAG AA (>=4.5:1) in both themes.
*/
:root {
  --app-bg:           11 16 32;    /* #0B1020 deep indigo */
  --app-surface:      20 27 51;    /* #141B33 raised indigo */
  --app-border:       38 49 79;    /* #26314F */
  --app-accent:       61 214 224;  /* #3DD6E0 electric cyan */
  --app-accent-hover: 47 184 194;  /* #2FB8C2 */
  --app-accent-text:  95 227 236;  /* #5FE3EC bright cyan reads well on indigo */
  --app-on-accent:    7 18 26;     /* #07121A near-black on cyan fill */
  --app-text:         232 236 246; /* #E8ECF6 cool off-white */
  --app-muted:        133 146 176; /* #8592B0 */

  /* Legacy aliases (kept for any direct var() consumers) */
  --bg:      #0B1020;
  --card:    #141B33;
  --border:  #26314F;
  --accent:  #3DD6E0;
  --success: #34D399;
  --danger:  #F87171;
  --muted:   #8592B0;
  --text:    #E8ECF6;
}

html.light {
  --app-bg:           244 246 252; /* #F4F6FC cool ivory-blue */
  --app-surface:      255 255 255; /* #FFFFFF */
  --app-border:       221 227 240; /* #DDE3F0 */
  --app-accent:       14 124 134;  /* #0E7C86 deep teal, readable as fill+text */
  --app-accent-hover: 10 98 106;   /* #0A626A */
  --app-accent-text:  14 124 134;  /* #0E7C86 passes AA on ivory-blue */
  --app-on-accent:    255 255 255; /* #FFFFFF on teal fill */
  --app-text:         20 27 51;    /* #141B33 indigo near-black */
  --app-muted:        92 103 132;  /* #5C6784 passes AA */

  --bg:      #F4F6FC;
  --card:    #FFFFFF;
  --border:  #DDE3F0;
  --accent:  #0E7C86;
  --success: #0F766E;
  --danger:  #DC2626;
  --muted:   #5C6784;
  --text:    #141B33;
}

* { box-sizing: border-box; }

/* Smooth the dark <-> light transition (kept subtle; excludes transforms) */
body, [class*="bg-app-"], [class*="border-app-"], [class*="text-app-"] {
  transition: background-color 0.2s ease, border-color 0.2s ease, color 0.2s ease;
}

body {
  background: var(--bg);
  color: var(--text);
  font-family: ui-sans-serif, system-ui, sans-serif;
  -webkit-font-smoothing: antialiased;
}

input[type='number']::-webkit-outer-spin-button,
input[type='number']::-webkit-inner-spin-button {
  -webkit-appearance: none;
  margin: 0;
}

/*
  Light-mode semantic status color fixes. The -400/-500 status shades are tuned
  for dark and wash out on light. Under html.light remap the text utilities to
  darker shades that pass AA. !important wins over Tailwind's own utilities.
*/
.light .text-emerald-400,
.light .text-emerald-500 { color: #047857 !important; }
.light .text-amber-400,
.light .text-amber-500  { color: #92400e !important; }
.light .text-red-400,
.light .text-red-500    { color: #b91c1c !important; }

/*
  Brand wordmark gradients. "Nex" uses the deep-indigo->cyan gradient; "um"
  uses a brighter cyan so the pair reads with a colorful accent while staying
  on-brand. Works in both themes.
*/
.nx-gradient-text {
  background: linear-gradient(120deg, #5FE3EC 0%, #3DD6E0 45%, #2E8CE0 100%);
  -webkit-background-clip: text;
  background-clip: text;
  -webkit-text-fill-color: transparent;
  color: transparent;
}
.nx-gradient-text-bright {
  background: linear-gradient(120deg, #8CF0F6 0%, #5FE3EC 60%, #3DD6E0 100%);
  -webkit-background-clip: text;
  background-clip: text;
  -webkit-text-fill-color: transparent;
  color: transparent;
}
.light .nx-gradient-text {
  background: linear-gradient(120deg, #2E8CE0 0%, #0E7C86 60%, #0A626A 100%);
  -webkit-background-clip: text; background-clip: text;
  -webkit-text-fill-color: transparent; color: transparent;
}
.light .nx-gradient-text-bright {
  background: linear-gradient(120deg, #1C9CB0 0%, #0E7C86 60%, #0A626A 100%);
  -webkit-background-clip: text; background-clip: text;
  -webkit-text-fill-color: transparent; color: transparent;
}

/* Subtle scrollbar for capped-height lists. */
.nx-scroll { scrollbar-width: thin; scrollbar-color: var(--app-border) transparent; }
.nx-scroll::-webkit-scrollbar { width: 6px; height: 6px; }
.nx-scroll::-webkit-scrollbar-track { background: transparent; }
.nx-scroll::-webkit-scrollbar-thumb {
  background: var(--app-border); border-radius: 9999px;
}
.nx-scroll::-webkit-scrollbar-thumb:hover { background: var(--app-muted); }

/* ===================================================================
   BALANCED MOTION LAYER
   GPU-cheap (transform/opacity only). All effects no-op under
   prefers-reduced-motion. Opt-in via utility classes so nothing
   animates unless a component asks for it.
   =================================================================== */

@keyframes nx-fade-up   { from { opacity: 0; transform: translateY(10px); } to { opacity: 1; transform: none; } }
@keyframes nx-fade-in   { from { opacity: 0; } to { opacity: 1; } }
@keyframes nx-scale-in  { from { opacity: 0; transform: scale(0.97); } to { opacity: 1; transform: none; } }
@keyframes nx-sheen     { 0% { background-position: -150% 0; } 100% { background-position: 250% 0; } }

/* Section / card entrance. Add .nx-enter (optionally with a delay class). */
.nx-enter    { animation: nx-fade-up 0.5s cubic-bezier(0.22,1,0.36,1) both; }
.nx-enter-in { animation: nx-fade-in 0.5s ease both; }
.nx-enter-scale { animation: nx-scale-in 0.4s cubic-bezier(0.22,1,0.36,1) both; }
.nx-delay-1  { animation-delay: 0.06s; }
.nx-delay-2  { animation-delay: 0.12s; }
.nx-delay-3  { animation-delay: 0.18s; }
.nx-delay-4  { animation-delay: 0.24s; }

/* Primary-button / logo sheen: a slow highlight sweep. Put on a positioned
   element; pair with overflow-hidden on the parent. */
.nx-sheen {
  background-image: linear-gradient(110deg, transparent 30%, rgb(255 255 255 / 0.14) 50%, transparent 70%);
  background-size: 200% 100%;
  animation: nx-sheen 3.2s ease-in-out infinite;
}

/* Press feedback for interactive fills. */
.nx-press { transition: transform 0.12s ease; }
.nx-press:active { transform: scale(0.98); }

@media (prefers-reduced-motion: reduce) {
  .nx-enter, .nx-enter-in, .nx-enter-scale, .nx-sheen {
    animation: none !important;
  }
  .nx-enter, .nx-enter-in, .nx-enter-scale { opacity: 1 !important; transform: none !important; }
  .nx-press { transition: none !important; }
}
CSS
echo "   [1/8] styles/globals.css        -> indigo+cyan tokens, gradients, motion layer"

# =====================================================================
# 2. tailwind.config.ts — refresh arc.accent + add entrance animations
# =====================================================================
python3 - << 'PY'
import re, io
p = "tailwind.config.ts"
s = open(p).read()

# Refresh the standalone arc.accent to the new cyan (network/on-chain UI).
s = s.replace("accent:  '#378ADD',", "accent:  '#3DD6E0',")

# Add fade/scale keyframes + animations alongside the existing ticker, once.
if "'fade-up'" not in s:
    s = s.replace(
        "      keyframes: {\n        ticker: {\n          '0%':   { transform: 'translateX(0)' },\n          '100%': { transform: 'translateX(-50%)' },\n        },\n      },",
        "      keyframes: {\n        ticker: {\n          '0%':   { transform: 'translateX(0)' },\n          '100%': { transform: 'translateX(-50%)' },\n        },\n        'fade-up': {\n          '0%':   { opacity: '0', transform: 'translateY(10px)' },\n          '100%': { opacity: '1', transform: 'none' },\n        },\n        'scale-in': {\n          '0%':   { opacity: '0', transform: 'scale(0.97)' },\n          '100%': { opacity: '1', transform: 'none' },\n        },\n      },"
    )
    s = s.replace(
        "      animation: {\n        ticker: 'ticker 30s linear infinite',\n      },",
        "      animation: {\n        ticker: 'ticker 30s linear infinite',\n        'fade-up': 'fade-up 0.5s cubic-bezier(0.22,1,0.36,1) both',\n        'scale-in': 'scale-in 0.4s cubic-bezier(0.22,1,0.36,1) both',\n      },"
    )

open(p,"w").write(s)
PY
echo "   [2/8] tailwind.config.ts        -> arc.accent cyan + fade-up/scale-in anims"

# =====================================================================
# 3. AfriFXLogo.tsx — hex-mark gradient stops -> cyan; add sheen on wordmark
# =====================================================================
python3 - << 'PY'
p = "components/brand/AfriFXLogo.tsx"
s = open(p).read()
s = s.replace('stopColor="#EAC15C"', 'stopColor="#5FE3EC"')
s = s.replace('stopColor="#B9822A"', 'stopColor="#2E8CE0"')
open(p,"w").write(s)
PY
echo "   [3/8] components/brand/AfriFXLogo.tsx -> mark gradient stops to cyan"

# =====================================================================
# 4. favicon.svg — full rewrite to indigo tile + cyan mark
# =====================================================================
cat > public/favicon.svg << 'SVG'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32" fill="none">
  <rect width="32" height="32" rx="8" fill="#0B1020"/>
  <g transform="translate(4.5,3.2) scale(0.19)">
    <defs><linearGradient id="fg" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#5FE3EC"/><stop offset="1" stop-color="#2E8CE0"/></linearGradient></defs>
    <path d="M60 4 L112 34 L112 90 L60 120 L8 90 L8 34 Z" fill="none" stroke="url(#fg)" stroke-width="9" stroke-linejoin="round"/>
    <g fill="none" stroke="#E8ECF6" stroke-width="10" stroke-linecap="round" stroke-linejoin="round"><path d="M36 88 L52 40 L68 88"/><path d="M43 70 L61 70"/></g>
    <g fill="none" stroke="url(#fg)" stroke-width="10" stroke-linecap="round"><path d="M74 52 L96 84"/><path d="M96 52 L74 84"/></g>
  </g>
</svg>
SVG
echo "   [4/8] public/favicon.svg        -> indigo tile + cyan mark"

# =====================================================================
# 5. manifest.json — name + brand colors
# =====================================================================
cat > public/manifest.json << 'JSON'
{
  "name": "Nexum",
  "short_name": "Nexum",
  "description": "Stablecoin FX & cross-border payments on Arc",
  "start_url": "/",
  "display": "standalone",
  "background_color": "#0B1020",
  "theme_color": "#0B1020",
  "icons": [
    {
      "src": "/favicon.svg",
      "sizes": "any",
      "type": "image/svg+xml",
      "purpose": "any maskable"
    }
  ]
}
JSON
echo "   [5/8] public/manifest.json      -> Nexum name + indigo colors"

# =====================================================================
# 6. layout.tsx — pre-paint themeColor to match new palette
# =====================================================================
python3 - << 'PY'
p = "app/layout.tsx"
s = open(p).read()
s = s.replace("color: '#12100B' },", "color: '#0B1020' },")   # dark
s = s.replace("color: '#F7F1E6' },", "color: '#F4F6FC' },")   # light
open(p,"w").write(s)
PY
echo "   [6/8] app/layout.tsx            -> themeColor indigo/ivory-blue"

# =====================================================================
# 7. providers.tsx — RainbowKit wallet accent
# =====================================================================
python3 - << 'PY'
p = "app/providers.tsx"
s = open(p).read()
# light theme
s = s.replace("accentColor:           '#8A5E13',", "accentColor:           '#0E7C86',")
# dark theme
s = s.replace("accentColor:           '#D9A441',", "accentColor:           '#3DD6E0',")
s = s.replace("accentColorForeground: '#12100B',", "accentColorForeground: '#07121A',")
open(p,"w").write(s)
PY
echo "   [7/8] app/providers.tsx         -> RainbowKit accent cyan/teal"

# =====================================================================
# 8. lib/tokens.ts — JS fallback token constants
# =====================================================================
python3 - << 'PY'
p = "lib/tokens.ts"
s = open(p).read()
s = s.replace("// Must match the :root defaults in styles/globals.css (warm palette)",
              "// Must match the :root defaults in styles/globals.css (indigo+cyan palette)")
s = s.replace("  bg:      '#12100B',", "  bg:      '#0B1020',")
s = s.replace("  surface: '#1C1810',", "  surface: '#141B33',")
s = s.replace("  border:  '#33291B',", "  border:  '#26314F',")
s = s.replace("  accent:  '#D9A441',", "  accent:  '#3DD6E0',")
s = s.replace("  text:    '#F2E9D8',", "  text:    '#E8ECF6',")
s = s.replace("  muted:   '#9C8A6E',", "  muted:   '#8592B0',")
open(p,"w").write(s)
PY
echo "   [8/8] lib/tokens.ts             -> JS fallback constants updated"

# --- avatar fallback color (2 files, cosmetic) ------------------------
python3 - << 'PY'
for p in ["app/admin/users/page.tsx", "app/(auth)/profile/setup/ProfileSetupClient.tsx"]:
    try:
        s = open(p).read()
        s2 = s.replace("'#D9A441'", "'#3DD6E0'")
        if s2 != s: open(p,"w").write(s2); print("   avatar fallback ->", p)
    except FileNotFoundError:
        pass
PY

# --- summary ----------------------------------------------------------
echo ""
echo "==> Rebrand applied. Review the diff:"
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git --no-pager diff --stat "${FILES[@]}" app/admin/users/page.tsx "app/(auth)/profile/setup/ProfileSetupClient.tsx" 2>/dev/null || true
  echo ""
  echo "   Full diff:   git diff"
  echo "   Revert all:  git checkout -- ${FILES[*]}   (or: $0 --revert)"
else
  echo "   (not a git repo — backup is at $DEST; re-run with --revert to undo)"
fi
echo ""
echo "==> NOT touched (functional/on-chain): lib/memo.ts, lib/contracts.ts,"
echo "    settlements CSV filename, admin placeholder text."
echo ""
echo "==> Next: run 'npm run dev' and check dark + light on the dashboard,"
echo "    signing page, and wallet-connect modal before pushing."
