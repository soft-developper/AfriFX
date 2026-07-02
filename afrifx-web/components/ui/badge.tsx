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
    arc:     'bg-app-accent/20 text-app-accent',
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
