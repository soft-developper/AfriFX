'use client'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { useAccount } from 'wagmi'

const API = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'

export interface Invoice {
  id:              string
  creator_address: string
  payer_address:   string | null
  amount:          number
  currency:        string
  description:     string | null
  notes:           string | null
  due_date:        number | null
  memo_ref:        string
  status:          'draft' | 'sent' | 'paid' | 'overdue' | 'cancelled'
  payment_tx_hash: string | null
  paid_at:         number | null
  created_at:      number
  updated_at:      number
}

export function useInvoices() {
  const { address } = useAccount()
  return useQuery<Invoice[]>({
    queryKey:        ['invoices', address],
    queryFn:         async () => {
      if (!address) return []
      const res = await fetch(`${API}/invoices?wallet=${address}`)
      return res.ok ? res.json() : []
    },
    enabled:         !!address,
    refetchInterval: 10_000,
  })
}

export function useInvoice(id: string | null) {
  return useQuery<Invoice | null>({
    queryKey:        ['invoice', id],
    queryFn:         async () => {
      if (!id) return null
      const res = await fetch(`${API}/invoices/${id}`)
      return res.ok ? res.json() : null
    },
    enabled:         !!id,
    refetchInterval: 5_000,
  })
}

export function useInvoiceByRef(ref: string | null) {
  return useQuery<Invoice | null>({
    queryKey:        ['invoice-ref', ref],
    queryFn:         async () => {
      if (!ref) return null
      const res = await fetch(`${API}/invoices/ref/${ref}`)
      return res.ok ? res.json() : null
    },
    enabled:         !!ref,
    refetchInterval: 5_000,
  })
}

export function useCreateInvoice() {
  const queryClient = useQueryClient()
  const { address } = useAccount()
  return useMutation({
    mutationFn: async (data: {
      amount: number; currency?: string; description?: string
      notes?: string; dueDate?: number; payerAddress?: string
    }) => {
      const res = await fetch(`${API}/invoices`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ walletAddress: address, ...data }),
      })
      return res.json()
    },
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ['invoices', address] }),
  })
}

export function useUpdateInvoiceStatus() {
  const queryClient = useQueryClient()
  const { address } = useAccount()
  return useMutation({
    mutationFn: async ({ id, status, paymentTxHash, paidAt }: {
      id: string; status: string; paymentTxHash?: string; paidAt?: number
    }) => {
      const res = await fetch(`${API}/invoices/${id}/status`, {
        method: 'PATCH',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ status, paymentTxHash, paidAt }),
      })
      return res.json()
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['invoices', address] })
    },
  })
}
