'use client'
import { Sun, Moon } from 'lucide-react'
import { useTheme } from '@/hooks/useTheme'
import { useEffect, useState } from 'react'

export function ThemeToggle({ className = '' }: { className?: string }) {
  const { theme, source, toggle } = useTheme()
  const [mounted, setMounted] = useState(false)
  useEffect(() => setMounted(true), [])

  // Avoid hydration mismatch render a neutral placeholder until mounted
  if (!mounted) {
    return <div className={`h-9 w-9 rounded-lg bg-app-border/50 ${className}`} />
  }

  const isDark = theme === 'dark'
  const label  = isDark ? 'Switch to light mode' : 'Switch to dark mode'

  return (
    <button
      onClick={toggle}
      title={source === 'auto' ? `${label} (currently auto, by time of day)` : label}
      aria-label={label}
      className={`relative flex h-9 w-9 items-center justify-center rounded-lg border border-app-border bg-app-surface text-app-muted transition-colors hover:bg-app-border hover:text-app-text ${className}`}
    >
      {isDark
        ? <Moon className="h-4 w-4" />
        : <Sun className="h-4 w-4" />}
      {source === 'auto' && (
        <span
          className="absolute -right-0.5 -top-0.5 h-2 w-2 rounded-full bg-app-accent"
          title="Auto (following time of day)"
        />
      )}
    </button>
  )
}
