'use client'
interface Props {
  onAction: (action: string, label: string) => void
  disabled: boolean
}

const ACTIONS = [
  { id: 'payment_sent',     emoji: '💸', label: 'Payment sent'         },
  { id: 'payment_received', emoji: '✅', label: 'Payment received'     },
  { id: 'need_more_time',   emoji: '⏰', label: 'Need more time'       },
]

export function QuickActions({ onAction, disabled }: Props) {
  return (
    <div className="flex flex-wrap gap-1.5 px-3 pb-2">
      {ACTIONS.map(({ id, emoji, label }) => (
        <button
          key={id}
          onClick={() => onAction(id, label)}
          disabled={disabled}
          className="flex items-center gap-1.5 rounded-full border border-app-border bg-app-surface px-2.5 py-1 text-xs text-app-muted transition-colors hover:border-app-accent hover:text-app-text disabled:opacity-40"
        >
          <span>{emoji}</span>
          <span>{label}</span>
        </button>
      ))}
    </div>
  )
}
