'use client'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { useAccount } from 'wagmi'

const API = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'

export interface TreasuryRule {
  id:                string
  wallet_address:    string
  name:              string
  trigger_threshold: number
  action_percent:    number | null
  action_amount:     number | null
  target_currency:   string
  status:            'active' | 'paused' | 'triggered'
  last_triggered:    number | null
  created_at:        number
}

export function useTreasuryRules() {
  const { address } = useAccount()
  return useQuery<TreasuryRule[]>({
    queryKey:        ['treasury-rules', address],
    queryFn:         async () => {
      if (!address) return []
      const res = await fetch(`${API}/treasury/rules?wallet=${address}`)
      return res.ok ? res.json() : []
    },
    enabled:         !!address,
    refetchInterval: 60_000,
  })
}

export function useCreateRule() {
  const queryClient = useQueryClient()
  const { address } = useAccount()
  return useMutation({
    mutationFn: async (data: Omit<TreasuryRule, 'id'|'wallet_address'|'status'|'last_triggered'|'created_at'>) => {
      const res = await fetch(`${API}/treasury/rules`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ walletAddress: address, ...data }),
      })
      return res.json()
    },
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ['treasury-rules', address] }),
  })
}

export function useToggleRule() {
  const queryClient = useQueryClient()
  const { address } = useAccount()
  return useMutation({
    mutationFn: async ({ id, status }: { id: string; status: string }) => {
      await fetch(`${API}/treasury/rules/${id}`, {
        method: 'PATCH',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ status }),
      })
    },
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ['treasury-rules', address] }),
  })
}

export function useDeleteRule() {
  const queryClient = useQueryClient()
  const { address } = useAccount()
  return useMutation({
    mutationFn: async (id: string) => {
      await fetch(`${API}/treasury/rules/${id}`, { method: 'DELETE' })
    },
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ['treasury-rules', address] }),
  })
}
