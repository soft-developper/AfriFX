#!/bin/bash
# ============================================================
# AfriFX -- Light-mode contrast fix
#
# In light mode, the status colors (emerald/amber/red) washed out:
#   * status BADGES (settled/released/cancelled) used a dark-green fill
#     with light-green text -> nearly invisible on the ivory background
#   * raw status TEXT (green amounts, "Release tx" links, red errors,
#     amber warnings) used the -400 shades, which fail AA on ivory
#
# Fix (dark theme untouched, all values checked to pass WCAG AA on ivory):
#   * components/ui/badge.tsx  -- light: fills (emerald/amber/red-100) with
#     dark text (-700/-800)
#   * tailwind.config.ts       -- registers the `light:` variant (targets
#     <html class="light">) so those badge classes actually compile
#   * styles/globals.css       -- remaps text-*-400/-500 to darker AA-passing
#     shades under .light, covering all 187 raw usages in one place
#
# Run from ~/AfriFX:  bash lightmode-contrast-fix.sh
# ============================================================
set -e
echo ""
echo "Applying light-mode contrast fix..."
echo ""

mkdir -p "afrifx-web/components/ui"
cat > "afrifx-web/components/ui/badge.tsx" << 'AFX_EOF'
import * as React from 'react'
import { cn } from '@/lib/utils'

interface BadgeProps extends React.HTMLAttributes<HTMLSpanElement> {
  variant?: 'default' | 'success' | 'warning' | 'danger' | 'arc'
}

export function Badge({ className, variant = 'default', ...props }: BadgeProps) {
  const styles = {
    default: 'bg-app-border text-app-text',
    success: 'bg-emerald-900/40 text-emerald-400 light:bg-emerald-100 light:text-emerald-800',
    warning: 'bg-amber-900/40 text-amber-400 light:bg-amber-100 light:text-amber-800',
    danger:  'bg-red-900/40 text-red-400 light:bg-red-100 light:text-red-700',
    arc:     'bg-app-accent/20 text-app-accent-text',
  }
  return (
    <span
      className={cn(
        'inline-flex items-center gap-1 rounded-full px-2.5 py-0.5 text-xs font-medium',
        styles[variant],
        className
      )}
      {...props}
    />
  )
}
AFX_EOF
echo "  afrifx-web/components/ui/badge.tsx"

mkdir -p "afrifx-web"
cat > "afrifx-web/tailwind.config.ts" << 'AFX_EOF'
import type { Config } from 'tailwindcss'
import plugin from 'tailwindcss/plugin'

const config: Config = {
  content: [
    './pages/**/*.{js,ts,jsx,tsx,mdx}',
    './components/**/*.{js,ts,jsx,tsx,mdx}',
    './app/**/*.{js,ts,jsx,tsx,mdx}',
  ],
  theme: {
    extend: {
      colors: {
        // Semantic tokens — driven by CSS variables (see globals.css).
        // Support opacity modifiers via the <alpha-value> placeholder.
        app: {
          bg:            'rgb(var(--app-bg) / <alpha-value>)',
          surface:       'rgb(var(--app-surface) / <alpha-value>)',
          border:        'rgb(var(--app-border) / <alpha-value>)',
          accent:        'rgb(var(--app-accent) / <alpha-value>)',
          'accent-hover':'rgb(var(--app-accent-hover) / <alpha-value>)',
          'accent-text': 'rgb(var(--app-accent-text) / <alpha-value>)',
          'on-accent':   'rgb(var(--app-on-accent) / <alpha-value>)',
          text:          'rgb(var(--app-text) / <alpha-value>)',
          muted:         'rgb(var(--app-muted) / <alpha-value>)',
        },
        arc: {
          bg:      '#080D1B',
          card:    '#0F1729',
          border:  '#1B2B4B',
          accent:  '#378ADD',
          success: '#10B981',
          danger:  '#EF4444',
          muted:   '#64748B',
          text:    '#E2E8F0',
        },
      },
      keyframes: {
        ticker: {
          '0%':   { transform: 'translateX(0)' },
          '100%': { transform: 'translateX(-50%)' },
        },
      },
      animation: {
        ticker: 'ticker 30s linear infinite',
      },
    },
  },
  plugins: [
    // Enables `light:` utilities that apply only when <html class="light">.
    // Mirrors how our theme system toggles the root class (see hooks/useTheme.tsx).
    plugin(({ addVariant }) => {
      addVariant('light', ':is(.light &)')
    }),
  ],
}
export default config
AFX_EOF
echo "  afrifx-web/tailwind.config.ts"

mkdir -p "afrifx-web/styles"
cat > "afrifx-web/styles/globals.css" << 'AFX_EOF'
@tailwind base;
@tailwind components;
@tailwind utilities;

/*
  Semantic color tokens as "R G B" channel triples so Tailwind can apply
  opacity modifiers, e.g. bg-app-accent/10.

  :root defines the DARK theme (warm espresso + gold). html.light overrides
  them with the LIGHT theme (warm ivory + deeper bronze). Every component
  reads these variables, so switching themes is purely a variable swap.

  Extra accent tokens keep text readable in BOTH themes:
    --app-accent        gold fill (buttons, bars, active states)
    --app-accent-hover  hover state for accent fills
    --app-accent-text   the accent used as READING text (links/labels);
                        deeper in light mode so it stays legible on ivory
    --app-on-accent     text/icons that sit ON a gold fill (dark in dark
                        mode, white in light mode) — replaces raw text-white
*/
:root {
  --app-bg:           18 16 11;    /* #12100B */
  --app-surface:      28 24 16;    /* #1C1810 */
  --app-border:       51 41 27;    /* #33291B */
  --app-accent:       217 164 65;  /* #D9A441 */
  --app-accent-hover: 196 143 46;  /* #C48F2E */
  --app-accent-text:  217 164 65;  /* #D9A441 — bright gold reads well on dark */
  --app-on-accent:    18 16 11;    /* #12100B — dark text on gold fill */
  --app-text:         242 233 216; /* #F2E9D8 */
  --app-muted:        156 138 110; /* #9C8A6E */

  /* Legacy aliases (kept for any direct var() consumers) */
  --bg:      #12100B;
  --card:    #1C1810;
  --border:  #33291B;
  --accent:  #D9A441;
  --success: #5BAE7B;
  --danger:  #D9694A;
  --muted:   #9C8A6E;
  --text:    #F2E9D8;
}

html.light {
  --app-bg:           247 241 230; /* #F7F1E6 — warm ivory */
  --app-surface:      255 253 248; /* #FFFDF8 — near-white warm surface */
  --app-border:       228 217 196; /* #E4D9C4 — soft sand */
  --app-accent:       138 94 19;   /* #8A5E13 — deep bronze, readable as fill+text on ivory */
  --app-accent-hover: 110 74 15;   /* #6E4A0F */
  --app-accent-text:  138 94 19;   /* #8A5E13 — passes AA (5.06:1) for link/label text */
  --app-on-accent:    255 255 255; /* #FFFFFF — white text on bronze fill */
  --app-text:         43 36 22;    /* #2B2416 — warm near-black */
  --app-muted:        107 95 73;   /* #6B5F49 — warm gray-brown, passes AA (5.56:1) */

  --bg:      #F7F1E6;
  --card:    #FFFDF8;
  --border:  #E4D9C4;
  --accent:  #8A5E13;
  --success: #2E7D53;
  --danger:  #C0492E;
  --muted:   #6B5F49;
  --text:    #2B2416;
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
  Light-mode semantic color fixes.

  The status colors (emerald/amber/red at the -400/-500 shades) are tuned for
  the dark theme and wash out on the light ivory background — a light green on
  near-white has almost no contrast. Under html.light we remap these specific
  text utilities to darker shades that pass WCAG AA on ivory, without touching
  the dark theme. Badge FILLS are handled separately via the `light:` variant
  in components/ui/badge.tsx.

  !important is required to win over Tailwind's own utility classes.
*/
.light .text-emerald-400,
.light .text-emerald-500 { color: #047857 !important; } /* emerald-700 — 4.88:1 on ivory */
.light .text-amber-400,
.light .text-amber-500  { color: #92400e !important; } /* amber-800 — passes on ivory */
.light .text-red-400,
.light .text-red-500    { color: #b91c1c !important; } /* red-700 — 5.76:1 on ivory */
AFX_EOF
echo "  afrifx-web/styles/globals.css"

echo ""
echo "Done. Now:"
echo "  cd afrifx-web && npm run build"
echo "  git add -A && git commit -m 'Fix light-mode contrast for status badges and text'"
echo "  git push"
