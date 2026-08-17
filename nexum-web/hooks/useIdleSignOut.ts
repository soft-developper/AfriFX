'use client'
// ============================================================
// useIdleSignOut — full sign-out after REAL inactivity (30 min).
//
// The Circle signing token lives in sessionStorage and dies on tab close by
// design (it grants signing power, shouldn't persist on disk). So its absence
// alone can't tell "quick reopen" from "gone for hours" — a fresh tab always
// lacks it. To distinguish them we keep our OWN last-activity timestamp in
// localStorage, which survives a tab close.
//
// Rule: if more than IDLE_MS has passed since the last recorded activity,
// sign the user OUT entirely and send them to /signin?reason=idle. Otherwise
// they stay signed in — a quick close/reopen does NOT nuke the session, and
// the app still re-auths lazily with Circle on the next transaction (the
// intended security model, unchanged).
//
// Checked on mount, on tab focus/visibility, and via a rolling timer.
// ============================================================
import { useEffect, useRef } from 'react'
import { useRouter } from 'next/navigation'
import { useAuth } from '@/hooks/useAuth'
import { clearSigningSession } from '@/hooks/useCircleTx'

const IDLE_MS = 30 * 60 * 1000          // 30 minutes of no activity
const ACTIVITY_KEY = 'nexum_last_activity'
const WRITE_THROTTLE_MS = 30 * 1000     // don't touch localStorage more than ~2x/min

function readLastActivity(): number {
  try {
    const v = localStorage.getItem(ACTIVITY_KEY)
    return v ? parseInt(v, 10) || 0 : 0
  } catch { return 0 }
}
function writeLastActivity(ts: number) {
  try { localStorage.setItem(ACTIVITY_KEY, String(ts)) } catch {}
}

export function useIdleSignOut() {
  const { account, signOut } = useAuth()
  const router = useRouter()
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null)
  const lastWrite = useRef(0)
  const signingOut = useRef(false)

  useEffect(() => {
    if (!account) return

    async function forceSignOut() {
      if (signingOut.current) return
      signingOut.current = true
      clearSigningSession()
      try { localStorage.removeItem(ACTIVITY_KEY) } catch {}
      await signOut().catch(() => {})
      router.replace('/signin?reason=idle')
    }

    // Idle for longer than the window? Sign out. Otherwise (re)arm the timer
    // for the remaining time.
    function evaluate() {
      const last = readLastActivity()
      // First run of a brand-new signed-in session: no stamp yet → start now.
      if (!last) { markActive(true); return }
      const idleFor = Date.now() - last
      if (idleFor >= IDLE_MS) { void forceSignOut(); return }
      arm(IDLE_MS - idleFor)
    }

    function arm(ms: number) {
      if (timer.current) clearTimeout(timer.current)
      timer.current = setTimeout(() => { void forceSignOut() }, ms)
    }

    // Record activity (throttled) and re-arm the full window.
    function markActive(force = false) {
      const now = Date.now()
      if (force || now - lastWrite.current > WRITE_THROTTLE_MS) {
        lastWrite.current = now
        writeLastActivity(now)
      }
      arm(IDLE_MS)
    }

    const events = ['mousemove', 'mousedown', 'keydown', 'scroll', 'touchstart', 'click']
    const onActivity = () => markActive()
    const onFocus = () => evaluate()   // returning to tab / regaining focus

    events.forEach(e => window.addEventListener(e, onActivity, { passive: true }))
    window.addEventListener('focus', onFocus)
    document.addEventListener('visibilitychange', onFocus)

    // On mount: decide immediately based on how long we've really been idle.
    evaluate()

    return () => {
      if (timer.current) clearTimeout(timer.current)
      events.forEach(e => window.removeEventListener(e, onActivity))
      window.removeEventListener('focus', onFocus)
      document.removeEventListener('visibilitychange', onFocus)
    }
  }, [account, signOut, router])
}
