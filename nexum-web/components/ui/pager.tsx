'use client'
// Reusable pager: Previous / Next + a "Showing X-Y of Z" label. Renders
// nothing when everything fits on one page, so it's safe to drop under any
// list unconditionally. Pair with usePaged().
import { Button } from '@/components/ui/button'
import { ChevronLeft, ChevronRight } from 'lucide-react'

export function Pager({
  page, totalPages, canPrev, canNext, next, prev, from, to, total,
  label = 'items',
}: {
  page: number
  totalPages: number
  canPrev: boolean
  canNext: boolean
  next: () => void
  prev: () => void
  from: number
  to: number
  total: number
  label?: string
}) {
  if (totalPages <= 1) return null
  return (
    <div className="mt-3 flex items-center justify-between gap-3 border-t border-app-border pt-3">
      <p className="text-[11px] text-app-muted">
        Showing {from}-{to} of {total} {label}
      </p>
      <div className="flex items-center gap-2">
        <Button variant="outline" size="sm" onClick={prev} disabled={!canPrev}>
          <ChevronLeft className="h-3.5 w-3.5" /> Previous
        </Button>
        <span className="text-[11px] text-app-muted">Page {page} of {totalPages}</span>
        <Button variant="outline" size="sm" onClick={next} disabled={!canNext}>
          Next <ChevronRight className="h-3.5 w-3.5" />
        </Button>
      </div>
    </div>
  )
}
