'use client'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { useAccount } from 'wagmi'

const API = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'

export interface Payment {
  id:                string
  sender_address:    string
  recipient_address: string
  amount:            number
  currency:          string
  local_currency:    string | null
  local_amount:      number | null
  description:       string | null
  invoice_ref:       string | null
  memo_ref:          string
  status:            'pending' | 'settled' | 'failed'
  arc_tx_hash:       string | null
  created_at:        number
  settled_at:        number | null
}

export function usePayments(type?: 'sent'|'received') {
  const { address } = useAccount()
  return useQuery<Payment[]>({
    queryKey:        ['payments', address, type],
    queryFn:         async () => {
      if (!address) return []
      const q   = type ? `&type=${type}` : ''
      const res = await fetch(`${API}/payments?wallet=${address}${q}`)
      return res.ok ? res.json() : []
    },
    enabled:         !!address,
    refetchInterval: 10_000,
  })
}

export function useCreatePayment() {
  const queryClient = useQueryClient()
  const { address } = useAccount()
  return useMutation({
    mutationFn: async (data: {
      recipientAddress: string; amount: number; currency?: string
      localCurrency?: string; description?: string
      invoiceRef?: string; arcTxHash?: string
    }) => {
      const res = await fetch(`${API}/payments`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ senderAddress: address, ...data }),
      })
      return res.json()
    },
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ['payments', address] }),
  })
}

export function useSettlementReport(fromTs?: number, toTs?: number) {
  const { address } = useAccount()
  return useQuery({
    queryKey: ['settlement-report', address, fromTs, toTs],
    queryFn:  async () => {
      if (!address) return null
      const params = new URLSearchParams({ wallet: address })
      if (fromTs) params.set('from', String(fromTs))
      if (toTs)   params.set('to',   String(toTs))
      const res = await fetch(`${API}/payments/report?${params}`)
      return res.ok ? res.json() : null
    },
    enabled: !!address,
  })
}
