import { SectionGuard } from '@/components/layout/SectionGuard'
import { CorridorCard } from '@/components/corridor/CorridorCard'
import { ClientOnly } from '@/components/ui/client-only'

export const metadata = { title: 'Corridor — AfriFX' }

function CorridorSkeleton() {
  return (
    <div className="w-full max-w-md rounded-2xl border border-app-border bg-app-surface p-5">
      <div className="mb-4 h-6 w-40 animate-pulse rounded bg-app-border" />
      <div className="mb-2 h-20 animate-pulse rounded-lg bg-app-border" />
      <div className="my-2 flex justify-center">
        <div className="h-8 w-8 animate-pulse rounded-full bg-app-border" />
      </div>
      <div className="mb-4 h-20 animate-pulse rounded-lg bg-app-border" />
      <div className="h-12 animate-pulse rounded-lg bg-app-border" />
    </div>
  )
}

function CorridorPageInner() {
  return (
    <div>
      <div className="mb-6">
        <h1 className="text-xl font-semibold text-app-text">Cross-border corridor</h1>
        <p className="text-sm text-app-muted">
          Send between African currencies in two steps via USDC.
          Both legs settle on Arc in under 1 second each.
        </p>
      </div>

      {/* Supported corridors info */}
      <div className="mb-6 rounded-xl border border-app-border bg-app-surface p-4">
        <p className="mb-2 text-xs font-medium text-app-text">Supported corridors</p>
        <div className="flex flex-wrap gap-2">
          {[
            'NGN → GHS', 'NGN → KES', 'NGN → ZAR', 'NGN → EGP',
            'GHS → KES', 'GHS → ZAR', 'KES → ZAR',
          ].map((c) => (
            <span key={c} className="rounded-full bg-app-bg px-2.5 py-1 text-xs text-app-muted">
              {c}
            </span>
          ))}
          <span className="rounded-full bg-app-bg px-2.5 py-1 text-xs text-app-muted">
            + all reverse pairs
          </span>
        </div>
      </div>

      <ClientOnly fallback={<CorridorSkeleton />}>
        <CorridorCard />
      </ClientOnly>
    </div>
  )
}

export default function CorridorPage() {
  return (
    <SectionGuard section="corridor">
      <CorridorPageInner />
    </SectionGuard>
  )
}
