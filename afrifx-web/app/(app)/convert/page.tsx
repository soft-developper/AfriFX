import { SwapCard } from '@/components/swap/SwapCard'
import { ClientOnly } from '@/components/ui/client-only'

export const metadata = { title: 'Convert — AfriFX' }

function SwapSkeleton() {
  return (
    <div className="w-full max-w-md rounded-2xl border border-app-border bg-app-surface p-5">
      <div className="mb-3 h-20 animate-pulse rounded-lg bg-app-border" />
      <div className="my-2 flex justify-center">
        <div className="h-8 w-8 animate-pulse rounded-full bg-app-border" />
      </div>
      <div className="mb-4 h-20 animate-pulse rounded-lg bg-app-border" />
      <div className="h-12 animate-pulse rounded-lg bg-app-border" />
    </div>
  )
}

export default function ConvertPage() {
  return (
    <div>
      <div className="mb-6">
        <h1 className="text-xl font-semibold text-app-text">Convert</h1>
        <p className="text-sm text-app-muted">
          Swap between local currencies and USDC. Settlement on Arc in under 1 second.
        </p>
      </div>
      <ClientOnly fallback={<SwapSkeleton />}>
        <SwapCard />
      </ClientOnly>
    </div>
  )
}
