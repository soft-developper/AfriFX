import { ClientOnly } from '@/components/ui/client-only'
import { CreateOfferClient } from './CreateOfferClient'

export default function CreateOfferPage() {
  return (
    <ClientOnly fallback={
      <div className="w-full max-w-md space-y-4">
        <div className="h-12 animate-pulse rounded-xl bg-[#0F1729]" />
        <div className="h-10 animate-pulse rounded-xl bg-[#0F1729]" />
        <div className="h-32 animate-pulse rounded-xl bg-[#0F1729]" />
        <div className="h-24 animate-pulse rounded-xl bg-[#0F1729]" />
        <div className="h-40 animate-pulse rounded-xl bg-[#0F1729]" />
        <div className="h-12 animate-pulse rounded-xl bg-[#0F1729]" />
      </div>
    }>
      <CreateOfferClient />
    </ClientOnly>
  )
}
