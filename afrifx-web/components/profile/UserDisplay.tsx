'use client'
import Link from 'next/link'
import { ProfileAvatar } from './ProfileAvatar'
import { useProfileByAddress } from '@/hooks/useProfile'
import { getAvatarColor } from '@/lib/avatar'
import { shortenAddress } from '@/lib/utils'

interface UserDisplayProps {
  address:     string | null | undefined
  size?:       'xs' | 'sm' | 'md'
  showAvatar?: boolean
  clickable?:  boolean
  suffix?:     string
  fallback?:   string   // custom fallback text if no address
}

export function UserDisplay({
ress,
  size       = 'sm',
  showAvatar = true,
  clickable  = true,
  suffix,
  fallback,
}: UserDisplayProps) {
  const { data: profile, isLoading } = useProfileByAddress(address)

  if (!address) {
    return <span className="text-xs text-app-muted">{fallback ?? '—'}</span>
  }

  if (isLoading) {
    return (
      <span className="inline-flex items-center gap-1.5">
        {showAvatar && (
          <span className={`${size === 'xs' ? 'h-5 w-5' : 'h-6 w-6'} animate-pulse rounded-full bg-app-border`} >
        )}
        <span className="h-3 w-20 animate-pulse rounded bg-app-border" />
      </span>
    )
  }

  const displayName = profile?.display_name ?? shortenAddress(address)
  const username    = profile?.username
  const color       = profile?.avatar_color ?? getAvatarColor(address)
  const verified    = profile?.verified ?? false

  const label = username ? `@${username}` : displayName

  const inner = (
    <span className="inline-flex items-center gap-1.5">
      {showAvatar && (
        <Profivatar
          displayName={displayName}
          avatarColor={color}
          size={size === 'md' ? 'sm' : 'xs'}
          verified={verified}
        />
      )}
      <span className={`font-medium ${
        size === 'xs' ? 'text-[11px]' :
        size === 'sm' ? 'text-xs'     : 'text-sm'
      } text-app-text`}>
        {label}
        {suffix && <span className="ml-1 text-app-accent-text text-[10px]">{suffix}</span>}
      </span>
    </span>
  )

  if (clickable && username) {
    return (
      <Link href={`/profile/${username}`} className="hover:opacity-80 transition-opacity">
        {inner}
      </Link>
    )
  }

  return inner
}
AFX_EOF
echo "  afrifx-web/components/profile/UserDisplay.tsx"

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
    success: 'bg-emerald-900/40 text-emerald-400',
    warning: 'bg-amber-900/40 text-amber-400',
    danger:  'bg-red-900/40 text-red-400',
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

mkdir -p "afrifx-web/components/ui"
cat > "afrifx-web/components/ui/button.tsx" << 'AFX_EOF'
import * as React from 'react'
import { Slot } from '@radix-ui/react-slot'
import { cva, type VariantProps } from 'class-variance-authority'
import { cn } from '@/lib/utils'

const buttonVariants = cva(
  'inline-flex items-center justify-center gap-2 rounded-md text-sm font-medium transition-all focus-visible:outline-none disabled:pointer-events-none disabled:opacity-50',
  {
    variants: {
      variant: {
        default:  'bg-app-accent text-app-on-accent hover:bg-app-accent-hover active:scale-[0.98]',
        outline:  'border border-app-border bg-transparent hover:bg-app-surface text-app-text',
        ghost:    'bg-transparent hover:bg-app-surface text-app-text',
        danger:   'bg-[#EF4444] text-white hover:bg-[#dc2626]',
        success:  'bg-[#10B981] text-white hover:bg-[#059669]',
      },
      size: {
        default: 'h-10 px-4 py-2',
        sm:      'h-8 px-3 text-xs',
        lg:      'h-12 px-6 text-base',
        icon:    'h-9 w-9',
      },
    },
    defaultVariants: { variant: 'default', size: 'default' },
  }
)

export interface ButtonProps
  extends React.ButtonHTMLAttributes<HTMLButtonElement>,
    VariantProps<typeof buttonVariants> {
  asChild?: boolean
}

const Button = React.forwardRef<HTMLButtonElement, ButtonProps>(
  ({ className, variant, size, asChild = false, ...props }, ref) => {
    cont Comp = asChild ? Slot : 'button'
    return <Comp className={cn(buttonVariants({ variant, size, className }))} ref={ref} {...props} />
  }
)
Button.displayName = 'Button'

export { Button, buttonVariants }
AFX_EOF
echo "  afrifx-web/components/ui/button.tsx"

mkdir -p "afrifx-web/components/wallet"
cat > "afrifx-web/components/wallet/ConnectButton.tsx" << 'AFX_EOF'
'use client'
// Thin wrapper — kept for backwards compatibility
// TopNav now uses RainbowKit ConnectButton.Custom directly
import { useConnal } from '@rainbow-me/rainbowkit'

export function ConnectButton({ label = 'Connect wallet' }: { label?: string }) {
  const { openConnectModal } = useConnectModal()
  return (
    <button
      onClick={openConnectModal}
      className="rounded-xl bg-app-accent px-4 py-2 text-sm font-medium text-app-on-accent transition-opacity hover:opacity-90">
      {label}
    </button>
  )
}
AFX_EOF
echo "  afrifx-web/components/wallet/ConnectButton.tsx"

mkdir -p "afrifx-web/hooks"
cat > "afrifx-web/hooks/useTheme.<< 'AFX_EOF'
'use client'
import { createContext, useContext, useEffect, useState, useCallback } from 'react'

export type Theme = 'light' | 'dark'
type ThemeSource = 'auto' | 'manual'

interface ThemeCtx {
  theme:     Theme
  source:    ThemeSource   // 'auto' = following the clock; 'manual' = user overrode
  toggle:    () => void
  setTheme:  (t: Theme) => void
  useAuto:   () => void    // clear manual override, go back to clock-based
}

const Ctx = createContext<ThemeCtx | null>(null)

const STORAGE_KEY = 'afrifx_theme' // stores 'light' | 'dark' when manual; absent = auto

// Clock-based default: light during the day (06:00–17:59), dark in the evening/night.
export function themeForNow(date = new Date()): Theme {
  const h = date.getHours()
  return h >= 6 && h < 18 ? 'light' : 'dark'
}

function applyTheme(t: Theme) {
  const root = document.documentElement
  if (t === 'light') root.classList.add('light')
  else               root.classList.remove('light')
}

export function ThemeProvider({ children }: { children: React.ReactNode }) {
  // Initial value is resolved by the inline script in layout.tsx before paint,
  // so we read the current DOM state here to stay in sync (no flash).
  const [theme, setThemeState]   = useState<Theme>('dark')
  const [source, setSource]      = useState<ThemeSource>('auto')

  useEffect(() => {
    const stored = (typeof window !== 'undefined'
      ? window.localStorage.getItem(STORAGE_KEY)
      : null) as Theme | null

    if (stored === 'light' || stored === 'dark') {
      setSource('manual')
      setThemeState(stored)
      applyTheme(stored)
    } else {
      const auto = themeForNow()
      setSource('auto')
      setThemeState(auto)
      applyTheme(auto)
    }
  }, [])

  // While in auto mode, re-check the clock periodically so the theme flips
  // on its own when the user crosses the day/night boundary mid-session.
  useEffect(() => {
    if (source !== 'auto') return
    const id = setInterval(() => {
      const auto = themeForNow()
      setThemeState(prev {
        if (prev !== auto) applyTheme(auto)
        return auto
      })
    }, 60_000)
    return () => clearInterval(id)
  }, [source])

  const setTheme = useCallback((t: Theme) => {
    setSource('manual')
    setThemeState(t)
    applyTheme(t)
    window.localStorage.setItem(STORAGE_KEY, t)
  }, [])

  const toggle = useCallback(() => {
    setTheme(theme === 'dark' ? 'light' : 'dark')
  }, [theme, setTheme])

  const useAuto = useCallback(() => {
    window.localStorage.removeItem(STORAGE_KEY)
    c auto = themeForNow()
    setSource('auto')
    setThemeState(auto)
    applyTheme(auto)
  }, [])

  return (
    <Ctx.Provider value={{ theme, source, toggle, setTheme, useAuto }}>
      {children}
    </Ctx.Provider>
  )
}

export function useTheme(): ThemeCtx {
  const ctx = useContext(Ctx)
  if (!ctx) throw new Error('useTheme must be used within ThemeProvider')
  return ctx
}
AFX_EOF
echo "  afrifx-web/hooks/useTheme.tsx"

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
    --app-accent        gold fill (buttons, bars, a states)
    --app-accent-hover  hover state for accent fills
    --app-accent-text   the accent used as READING text (links/labels);
                        deeper in light mode so it stays legible on ivory
    --app-on-accent     text/icons that sit ON a gold fill (dark in dark
                        mode, white in light mode) — replaces raw text-white
*/
:root {
  --app-bg:           18 16 11;    /* #12100B */
  --app-surface:      28 24 16;    /* #1C1810 */
  --app-border:       51 41 27;    /* #3329*/
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
  --app-accent-text:  138 94 19;   /* #8A5E13 — pass AA (5.06:1) for link/label text */
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
AFX_EF
echo "  afrifx-web/styles/globals.css"

mkdir -p "afrifx-web"
cat > "afrifx-web/tailwind.config.ts" << 'AFX_EOF'
import type { Config } from 'tailwindcss'

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
  plugins: [],
}
export default config
AFX_EOF
echo "  afrifx-web/tailwind.config.ts"

echo ""
echo "======================================================"
echo "Phase C complete -- dark/light toggle applied."
echo ""
echo "  NEXT:"
echo "    cd afrifx-web && npm run build"
echo "    git add -A && git commit -m 'Phase C: dark/light theme toggle'"
echo "    git push"
echo "======================================================"
