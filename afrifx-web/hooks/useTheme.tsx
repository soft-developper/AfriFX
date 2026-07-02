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
      setThemeState(prev => {
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
    const auto = themeForNow()
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
