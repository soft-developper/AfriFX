import { ClientOnly } from '@/components/ui/client-only'
import { PayrollCreateContent } from './PayrollCreateContent'

export default function PayrollPage() {
  return (
    <ClientOnly fallback={
      <div className="space-y-4">
        <div className="h-12 animate-pulse rounded-xl bg-app-surface" />
        <div className="h-96 animate-pulse rounded-xl bg-app-surface" />
      </div>
    }>
      <PayrollCreateContent />
    </ClientOnly>
  )
}
