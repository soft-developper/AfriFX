import { ClientOnly } from '@/components/ui/client-only'
import { WalletContent } from './WalletContent'

export default function WalletPage() {
  return (
    <ClientOnly fallback={
      <div className="space-y-4">
        <div className="h-48 animate-pulse rounded-xl bg-app-surface" />
        <div className="grid gap-4 lg:grid-cols-3">
          {[1,2,3].map(i => <div key={i} className="h-32 animate-pulse rounded-xl bg-app-surface" />)}
        </div>
        <div className="h-64 animate-pulse rounded-xl bg-app-surface" />
      </div>
    }>
      <WalletContent />
    </ClientOnly>
  )
}
