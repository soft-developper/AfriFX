'use client'
// ============================================================
// usePaged — client-side pagination for any array.
//
// Shows the most-recent `pageSize` (default 20) items per page and folds the
// rest behind Next/Previous. Pass an array that's already in the order you
// want displayed (e.g. newest first). Resets to page 1 whenever the list
// length changes, so switching a filter tab doesn't strand you on a page that
// no longer exists.
// ============================================================
import { useState, useEffect, useMemo } from 'react'

export interface Paged<T> {
  page:       number
  totalPages: number
  pageItems:  T[]
  canPrev:    boolean
  canNext:    boolean
  next:       () => void
  prev:       () => void
  setPage:    (p: number) => void
  // 1-based inclusive range of what's shown, plus the total, for a label.
  from:       number
  to:         number
  total:      number
}

export function usePaged<T>(items: T[], pageSize = 20): Paged<T> {
  const [page, setPage] = useState(1)
  const total = items.length
  const totalPages = Math.max(1, Math.ceil(total / pageSize))

  // If the underlying list shrinks/grows (filter switch, refetch), go back to
  // page 1 rather than showing an out-of-range empty page.
  useEffect(() => { setPage(1) }, [total])

  // Clamp in case page somehow exceeds the range.
  const safePage = Math.min(page, totalPages)

  const pageItems = useMemo(() => {
    const start = (safePage - 1) * pageSize
    return items.slice(start, start + pageSize)
  }, [items, safePage, pageSize])

  const from = total === 0 ? 0 : (safePage - 1) * pageSize + 1
  const to   = Math.min(safePage * pageSize, total)

  return {
    page: safePage,
    totalPages,
    pageItems,
    canPrev: safePage > 1,
    canNext: safePage < totalPages,
    next: () => setPage(p => Math.min(p + 1, totalPages)),
    prev: () => setPage(p => Math.max(p - 1, 1)),
    setPage,
    from, to, total,
  }
}
