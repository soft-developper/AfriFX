import { CorridorCard } from '@/components/corridor/CorridorCard'
import { ClientOnly } from '@/components/ui/client-only'

export const metadata = { title: 'Corridor — AfriFX' }

function CorridorSkeleton() {
  return (
    <div className="w-full max-w-md rounded-2xl border border-[#1B2B4B] bg-[#0F1729] p-5">
      <div className="mb-4 h-6 w-40 animate-pulse rounded bg-[#1B2B4B]" />
      <div className="mb-2 h-20 animate-pulse rounded-lg bg-[#1B2B4B]" />
      <div className="my-2 flex justify-center">
        <div className="h-8 w-8 animate-pulse rounded-full bg-[#1B2B4B]" />
      </div>
      <div className="mb-4 h-20 animate-pulse rounded-lg bg-[#1B2B4B]" />
      <div className="h-12 animate-pulse rounded-lg bg-[#1B2B4B]" />
    </div>
  )
}

export default function CorridorPage() {
  return (
    <div>
      <div className="mb-6">
        <h1 className="text-xl font-semibold text-[#E2E8F0]">Cross-border corridor</h1>
        <p className="text-sm text-[#64748B]">
          Send between African currencies in two steps via USDC.
          Both legs settle on Arc in under 1 second each.
        </p>
      </div>

      {/* Supported corridors info */}
      <div className="mb-6 rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-4">
        <p className="mb-2 text-xs font-medium text-[#E2E8F0]">Supported corridors</p>
        <div className="flex flex-wrap gap-2">
          {[
            'NGN → GHS', 'NGN → KES', 'NGN → ZAR', 'NGN → EGP',
            'GHS → KES', 'GHS → ZAR', 'KES → ZAR',
          ].map((c) => (
            <span key={c} className="rounded-full bg-[#080D1B] px-2.5 py-1 text-xs text-[#64748B]">
              {c}
            </span>
          ))}
          <span className="rounded-full bg-[#080D1B] px-2.5 py-1 text-xs text-[#64748B]">
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
