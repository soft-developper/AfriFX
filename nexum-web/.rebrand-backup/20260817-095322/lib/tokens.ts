'use client'
import { useEffect, useState } from 'react'

/*
  Some UI needs colors as JavaScript strings rather than Tailwind classes
  Recharts configs, inline style props, avatar fallbacks, etc. Those can't use
  utility classes, so they read the same semantic tokens from CSS variables
  here. This keeps charts and inline styles in sync with the active theme
  (including a future light mode) instead of hardcoding hex values.

  The DEFAULT_TOKENS below mirror the :root defaults in globals.css and act as
  the server-render / pre-hydration fallback. useTokens() resolves the live
  values on the client so a theme change is reflected everywhere.
*/

export interface Tokens {
  bg:      string
  surface: string
  border:  string
  accent:  string
  text:    string
  muted:   string
}

// Must match the :root defaults in styles/globals.css (warm palette)
export const DEFAULT_TOKENS: Tokens = {
  bg:      '#12100B',
  surface: '#1C1810',
  border:  '#33291B',
  accent:  '#D9A441',
  text:    '#F2E9D8',
  muted:   '#9C8A6E',
}

const VAR_MAP: Record<keyof Tokens, string> = {
  bg:      '--app-bg',
  surface: '--app-surface',
  border:  '--app-border',
  accent:  '--app-accent',
  text:    '--app-text',
  muted:   '--app-muted',
}

// Read a "R G B" CSS variable triple and return an rgb() color string
function readVar(name: string): string | null {
  if (typeof window === 'undefined') return null
  const raw = getComputedStyle(document.documentElement).getPropertyValue(name).trim()
  if (!raw) return null
  const parts = raw.split(/\s+/).map(Number)
  if (parts.length === 3 && parts.every(n => !Number.isNaN(n))) {
    return `rgb(${parts[0]}, ${parts[1]}, ${parts[2]})`
  }
  return raw
}

export function resolveTokens(): Tokens {
  if (typeof window === 'undefined') return DEFAULT_TOKENS
  const out = { ...DEFAULT_TOKENS }
  ;(Object.keys(VAR_MAP) as (keyof Tokens)[]).forEach(k => {
    const v = readVar(VAR_MAP[k])
    if (v) out[k] = v
  })
  return out
}

// Hook: resolves live token values on mount (and re-runs on theme change)
export function useTokens(): Tokens {
  const [tokens, setTokens] = useState<Tokens>(DEFAULT_TOKENS)
  useEffect(() => {
    setTokens(resolveTokens())
    const observer = new MutationObserver(() => setTokens(resolveTokens()))
    observer.observe(document.documentElement, {
      attributes: true,
      attributeFilter: ['class', 'data-theme', 'style'],
    })
    return () => observer.disconnect()
  }, [])
  return tokens
}
