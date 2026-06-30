'use client'
import { UserDisplay } from '@/components/profile/UserDisplay'

interface Props {
  makerAddress: string
  takerAddress: string | null | undefined
  isMaker:      boolean
  isTaker:      boolean
}

export function OfferParties({ makerAddress, takerAddress, isMaker, isTaker }: Props) {
  return (
    <div className="space-y-2 text-xs">
      <div className="flex items-center justify-between">
        <span className="text-[#64748B]">Seller (receives local)</span>
        <UserDisplay
          address={makerAddress}
          size="xs"
          suffix={isMaker ? '(you)' : undefined}
        />
      </div>
      <div className="flex items-center justify-between">
        <span className="text-[#64748B]">Buyer (receives USDC)</span>
        {takerAddress
          ? <UserDisplay address={takerAddress} size="xs" suffix={isTaker ? '(you)' : undefined} />
          : <span className="text-[#64748B] text-xs">Waiting for buyer…</span>
        }
      </div>
    </div>
  )
}
