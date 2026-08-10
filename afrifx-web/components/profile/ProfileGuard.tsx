'use client'
import { useEffect } from 'react'
import { useAccountAddress as useAccount } from '@/hooks/useAccountAddress'
import { useRouter } from 'next/navigation'
import { useProfile } from '@/hooks/useProfile'

export function ProfileGuard({ children }: { children: React.ReactNode }) {
  const { isConnected, address } = useAccount()
  const { data: profile, isLoading } = useProfile()
  const router = useRouter()

  useEffect(() => {
    if (!isConnected || isLoading) return
    if (address && !profile) {
      router.push('/profile/setup')
    }
  }, [isConnected, isLoading, profile, address, router])

  return <>{children}</>
}
