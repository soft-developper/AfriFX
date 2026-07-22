import { BridgeCard } from '@/components/bridge/BridgeCard'
import { ClientOnly } from '@/components/ui/client-only'

export const metadata = { title: 'Bridge, AfriFX' }

function BridgeSkeleton() {
  return (
    <div className="w-full max-w-md rounded-2xl border border-app-border bg-app-surface p-5">
      <div className="mb-4 h-5 w-32 animate-pulse rounded bg-app-border" />
      <div className="mb-3 h-11 animate-pulse rounded-lg bg-app-border" />
      <div className="my-2 flex justify-center">
        <div className="h-8 w-8 animate-pulse rounded-full bg-app-border" />
      </div>
      <div className="mb-3 h-11 animate-pulse rounded-lg bg-app-border" />
      <div className="mb-4 h-11 animate-pulse rounded-lg bg-app-border" />
      <div className="h-11 animate-pulse rounded-lg bg-app-border" />
    </div>
  )
}

/*
  No SectionGuard here on purpose: the maintenance sections are a fixed list
  ('convert' | 'corridor' | 'send' | ...) and 'bridge' isn't one of them.
  Adding a new section would mean a backend change; that can come later if you
  want to be able to take the bridge down independently.
*/
export default function BridgePage() {
  return (
    <div>
      <div className="mb-6">
        <h1 className="text-xl font-semibold text-app-text">Bridge</h1>
        <p className="text-sm text-app-muted">
          Move native USDC between Arc and other chains using Circle&apos;s CCTP.
        </p>
      </div>
      <ClientOnly fallback={<BridgeSkeleton />}>
        <BridgeCard />
      </ClientOnly>
    </div>
  )
}
