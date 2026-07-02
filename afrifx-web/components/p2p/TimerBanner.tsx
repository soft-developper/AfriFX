'use client'
import { useCountdown } from '@/hooks/useCountdown'
import { Clock, AlertTriangle, CheckCircle } from 'lucide-react'

interface TimerBannerProps {
  deadline:     number | null | undefined
  totalSeconds: number | null | undefined
  phase:        'taker' | 'maker'        // whose turn it is
  isMine:       boolean                  // is this timer for the current user?
}

export function TimerBanner({ deadline, totalSeconds, phase, isMine }: TimerBannerProps) {
  const { formatted, pctElapsed, isExpired, isWarning, isDanger } = useCountdown(deadline, totalSeconds)

  if (!deadline) return null

  // Dynamic color scheme based on % elapsed
  const scheme = isExpired
    ? { bg: 'bg-red-950/60',    border: 'border-red-500/50',   bar: 'bg-red-500',    text: 'text-red-300',    icon: 'text-red-400',    time: 'text-red-300'    }
    : isDanger
    ? { bg: 'bg-red-950/40',    border: 'border-red-500/40',   bar: 'bg-red-500',    text: 'text-red-300',    icon: 'text-red-400',    time: 'text-red-200'    }
    : isWarning
    ? { bg: 'bg-amber-950/40',  border: 'border-amber-500/40', bar: 'bg-amber-400',  text: 'text-amber-300',  icon: 'text-amber-400',  time: 'text-amber-200'  }
    : { bg: 'bg-app-surface',     border: 'border-app-border',    bar: 'bg-app-accent',  text: 'text-app-muted',  icon: 'text-app-accent',  time: 'text-app-text'  }

  const phaseLabel = phase === 'taker'
    ? isMine ? 'Your window to send local currency' : "Waiting for taker to send"
    : isMine ? 'Your window to confirm receipt'      : 'Waiting for maker to confirm'

  const urgencyLabel = isExpired
    ? 'Time expired'
    : isDanger
    ? 'Urgent — act now'
    : isWarning
    ? 'Running low'
    : 'Time remaining'

  return (
    <div className={`w-full rounded-xl border px-5 py-4 ${scheme.bg} ${scheme.border}`}>
      {/* Top row — label + urgency */}
      <div className="mb-3 flex items-center justify-between">
        <div className="flex items-center gap-2">
          {isExpired || isDanger
            ? <AlertTriangle className={`h-4 w-4 ${scheme.icon}`} />
            : <Clock className={`h-4 w-4 ${scheme.icon}`} />
          }
          <span className={`text-sm font-medium ${scheme.text}`}>{phaseLabel}</span>
        </div>
        <span className={`text-xs font-medium ${scheme.text}`}>{urgencyLabel}</span>
      </div>

      {/* Large countdown display */}
      <div className={`mb-3 text-center font-mono text-4xl font-bold tracking-wider ${scheme.time}`}
        style={{ fontVariantNumeric: 'tabular-nums' }}>
        {formatted}
      </div>

      {/* Progress bar — depletes left to right */}
      <div className="h-2 w-full overflow-hidden rounded-full bg-app-border">
        <div
          className={`h-full rounded-full transition-all duration-1000 ${scheme.bar}`}
          style={{ width: `${Math.max(0, 100 - pctElapsed)}%` }}
        />
      </div>

      {/* Bottom label */}
      <div className="mt-2 flex justify-between text-[10px] text-app-muted">
        <span>Start</span>
        <span className={`font-medium ${pctElapsed > 90 ? 'text-red-400' : pctElapsed > 70 ? 'text-amber-400' : 'text-app-muted'}`}>
          {Math.round(pctElapsed)}% elapsed
        </span>
        <span>Deadline</span>
      </div>
    </div>
  )
}
