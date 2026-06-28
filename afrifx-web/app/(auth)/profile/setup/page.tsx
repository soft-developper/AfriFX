import { ClientOnly } from '@/components/ui/client-only'
import { ProfileSetupClient } from './ProfileSetupClient'

export default function ProfileSetupPage() {
  return (
    <ClientOnly fallback={
      <div className="flex min-h-screen items-center justify-center">
        <div className="w-full max-w-sm space-y-4">
          <div className="h-12 animate-pulse rounded-xl bg-[#0F1729]" />
          <div className="h-64 animate-pulse rounded-xl bg-[#0F1729]" />
        </div>
      </div>
    }>
      <ProfileSetupClient />
    </ClientOnly>
  )
}
