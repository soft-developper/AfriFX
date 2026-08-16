'use client'
// ============================================================
// useIdleSignOut — full sign-out after real inactivity.
//
// Circle's signing token lasts ~60 min, after which transactions can't be
// signed until you re-authenticate. Leaving the user "logged in but unable to
// act" is confusing, so once the app has been idle long enough we sign them
// OUT entirely and send them to /signin?reason=idle — an unambiguous "please
// sign in again" rather than a silent mid-action failure.
//
// Idle = no user activity (pointer, key, scroll, touch, focus) for IDLE_MS.
// Any activity resets the timer. We also re-check on tab focus, so a laptop
// that slept past the window signs out on return rather than on a dead timer.
// ============================================================
import { useEffect, useRef } from 'react'
import { useRouter } from 'next/navigation'
import { useAuth } from '@/hooks/useAuth'
import { getSigningSession, clearSigningSession } from '@/hooks/useCircleTx'

const IDLE_MS = 30 * 60 * 1000 // 30 minutes of no activity

export function useIdleSignOut() {
  const { account, signOut } = useAuth()
  const router = useRouter()
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null)
  const signingOut = useRef(false)

  useEffect(() => {
    if (!account) return

    async function forceSignOut() {
      if (signingOut.current) return
      signingOut.current = true
      clearSigningSession()
      await signOut().catch(() => {})
      router.replace('/signin?reason=idle')
    }

    function resetTimer() {
      if (timer.current) clearTimeout(timer.current)
      timer.current = setTimeout(() => { void forceSignOut() }, IDLE_MS)
    }

    // Returning to the tab after a long sleep: if the signing token already
    // expired, don't wait out a fresh timer — sign out now.
    function onFocus() {
      if (!getSigningSession()) void forceSignOut()
      else resetTimer()
    }

    const events = ['mousemove', 'mousedown', 'keydown', 'scroll', 'touchstart', 'click']
    const onActivity = () => resetTimer()
    events.forEach(e => window.addEventListener(e, onActivity, { passive: true }))
    window.addEventListener('focus', onFocus)
    document.addEventListener('visibilitychange', onFocus)

    resetTimer()

    return () => {
      if (timer.current) clearTimeout(timer.current)
      events.forEach(e => window.removeEventListener(e, onActivity))
      window.removeEventListener('focus', onFocus)
      document.removeEventListener('visibilitychange', onFocus)
    }
  }, [account, signOut, router])
}
