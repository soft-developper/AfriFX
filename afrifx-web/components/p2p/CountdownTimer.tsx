'use client'
import { useCountdown } from '@/hooks/useCountdown'
import { Clock, AlertTriangle } from 'lucide-react'

interface CountdownTimerProps {
  deadline:     number | null | undefined
  totalSeconds?: number | null | undefined
  label:        string
}

export function CountdownTimer({ deadline, totalSeconds, label }: CountdownTimerProps) {
  const { formatted, isExpired, isWarning, isDanger } = useCountdown(deadline, totalSeconds)
  if (!deadline) return null

  return (
    <div className={`flex items-center gap-2 rounded-lg px-3 py-2 text-xs
      ${isExpired || isDanger
        ? 'border border-red-900/50 bg-red-900/20 text-red-400'
        : isWarning
        ? 'border border-amber-900/50 bg-amber-900/20 text-amber-400'
        : 'border border-[#1B2B4B] bg-[#080D1B] text-[#64748B]'
      }`}>
      {isExpired || isDanger
        ? <AlertTriangle className="h-3.5 w-3.5 shrink-0" />
        : <Clock className="h-3.5 w-3.5 shrink-0" />
      }
      <span>{label}</span>
      <span className={`ml-auto font-mono font-medium
        ${isExpired || isDanger ? 'text-red-300' : isWarning ? 'text-amber-300' : 'text-[#E2E8F0]'}`}>
        {formatted}
      </span>
    </div>
  )
}
