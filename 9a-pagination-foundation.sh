#!/usr/bin/env bash
# ============================================================
# 9a-pagination-foundation.sh   (run once; safe alone; deploy web)
#
# Item 4, part 1 of 3: the reusable pieces every list will use.
#   - hooks/usePaged.ts   : usePaged(items, pageSize=20) -> current page slice,
#                           total pages, next/prev, canPrev/canNext, showing.
#                           Resets to page 1 when the list length changes (so a
#                           filter-tab switch returns to the first page).
#   - components/ui/pager.tsx : <Pager> Previous/Next + "Showing X-Y of Z".
#                               Hidden automatically when there's only one page.
#
# This script only ADDS two files; it changes no existing behaviour. Parts 9b
# (user lists) and 9c (admin lists) wire these in.
# ============================================================
set -euo pipefail

if [ -d "nexum-web" ]; then WEB="nexum-web"
elif [ -d "$HOME/AfriFX/nexum-web" ]; then WEB="$HOME/AfriFX/nexum-web"
else echo "ERROR: run from repo root or ~/AfriFX"; exit 1; fi

HOOK="$WEB/hooks/usePaged.ts"
PAGER="$WEB/components/ui/pager.tsx"
[ -f "$HOOK" ]  && { echo "ERROR: $HOOK exists — aborting"; exit 1; }
[ -f "$PAGER" ] && { echo "ERROR: $PAGER exists — aborting"; exit 1; }

cat > "$HOOK" <<'TS'
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
TS
echo "Created $HOOK"

cat > "$PAGER" <<'TSX'
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
TSX
echo "Created $PAGER"

echo
echo "Deploy (web only; safe to deploy now or bundle with 9b/9c):"
echo "  cd $WEB && rm -rf .next && npx tsc --noEmit && npm run build"
echo "  git add -A && git commit -m 'feat(ui): reusable usePaged hook + Pager component' && git push"
