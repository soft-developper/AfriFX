import { ClientOnly } from '@/components/ui/client-only'
import { TreasuryContent } from './TreasuryContent'

export default function TreasuryPage() {
  return (
    <ClientOnly fallback={
      <div className="space-y-4">
        <div className="h-32 animate-pulse rounded-xl bg-[#0F1729]" />
        <div className="grid gap-4 lg:grid-cols-2">
          <div className="h-64 animate-pulse rounded-xl bg-[#0F1729]" />
          <div className="h-64 animate-pulse rounded-xl bg-[#0F1729]" />
        </div>
      </div>
    }>
      <TreasuryContent />
    </ClientOnly>
  )
}
