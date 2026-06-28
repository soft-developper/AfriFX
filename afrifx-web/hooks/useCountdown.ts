'use client'
import { useState, useEffect } from 'react'

export interface CountdownState {
  secondsLeft:    number
  formatted:      string
  pctElapsed:     number   // 0–100: how much of total time has passed
  isExpired:      boolean
  isWarning:      boolean  // > 70% elapsed
  isDanger:       boolean  // > 90% elapsed → RED
}

export function useCountdown(
  deadlineUnix:   number | null | undefined,
  totalSeconds:   number | null | undefined,  // original timer duration
): CountdownState {
  const [secondsLeft, setSecondsLeft] = useState(0)

  useEffect(() => {
    if (!deadlineUnix) { setSecondsLeft(0); return }
    const update = () => {
      const diff = deadlineUnix - Math.floor(Date.now() / 1000)
      setSecondsLeft(Math.max(0, diff))
    }
    update()
    const t = setInterval(update, 1000)
    return () => clearInterval(t)
  }, [deadlineUnix])

  const total      = totalSeconds ?? 1800
  const elapsed    = total - secondsLeft
  const pctElapsed = Math.min(100, Math.max(0, (elapsed / total) * 100))

  const hours   = Math.floor(secondsLeft / 3600)
  const minutes = Math.floor((secondsLeft % 3600) / 60)
  const seconds = secondsLeft % 60

  const formatted = !deadlineUnix
    ? '—'
    : secondsLeft === 0
    ? 'Expired'
    : hours > 0
    ? `${hours}h ${String(minutes).padStart(2,'0')}m ${String(seconds).padStart(2,'0')}s`
    : minutes > 0
    ? `${String(minutes).padStart(2,'0')}m ${String(seconds).padStart(2,'0')}s`
    : `00m ${String(seconds).padStart(2,'0')}s`

  return {
    secondsLeft,
    formatted,
    pctElapsed,
    isExpired: secondsLeft === 0 && !!deadlineUnix,
    isWarning: pctElapsed > 70 && pctElapsed <= 90,
    isDanger:  pctElapsed > 90,
  }
}
