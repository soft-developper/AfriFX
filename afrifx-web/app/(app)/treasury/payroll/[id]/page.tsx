import { ClientOnly } from '@/components/ui/client-only'
import { PayrollExecuteContent } from './PayrollExecuteContent'

export default function PayrollBatchPage() {
  return (
    <ClientOnly fallback={
      <div className="space-y-4">
        <div className="h-12 animate-pulse rounded-xl bg-[#0F1729]" />
        <div className="h-96 animate-pulse rounded-xl bg-[#0F1729]" />
      </div>
    }>
      <PayrollExecuteContent />
    </ClientOnly>
  )
}
