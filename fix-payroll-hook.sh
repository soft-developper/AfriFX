#!/usr/bin/env bash
# ============================================================
# fix-payroll-hook.sh
#
# FIX for a regression introduced by phase3-cutover.sh.
#
# WHAT HAPPENED
# phase3-cutover.sh rewrote afrifx-web/hooks/usePayroll.ts to migrate
# its useAccount import. It wrote that file from a copy of the repo that
# PREDATED the payroll multichain work, so it silently reverted
# `dest_chain` off PayrollBatch and `destChain` off the create mutation.
#
# PayrollCreateContent.tsx and PayrollExecuteContent.tsx still referenced
# both, which is the two tsc errors you saw:
#   'destChain' does not exist in type ...
#   Property 'dest_chain' does not exist on type 'PayrollBatch'
#
# Only this one file was affected. The other multichain files
# (PayrollCreateContent, PayrollExecuteContent, useGatewaySend,
# LandingFeatures) were not in the cutover and are untouched.
#
# THE FIX
# usePayroll.ts, with BOTH the multichain fields restored AND the
# useAccountAddress migration kept.
#
# VERIFIED: applied on top of payroll-multichain + all phase scripts,
# afrifx-web `tsc --noEmit` is clean and `npm run build` succeeds.
# ============================================================
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

echo "→ Restoring afrifx-web/hooks/usePayroll.ts…"
cat > 'afrifx-web/hooks/usePayroll.ts' <<'AFX_FIX_EOF'
'use client'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { useAccountAddress as useAccount } from '@/hooks/useAccountAddress'

const API = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'

export interface PayrollRecipient {
  id:             string
  batch_id:       string
  name:           string | null
  wallet_address: string
  amount:         number
  currency:       string
  status:         'pending' | 'sent' | 'failed'
  tx_hash:        string | null
  memo_ref:       string | null
  created_at:     number
}

export interface PayrollBatch {
  id:              string
  wallet_address:  string
  name:            string
  description:     string | null
  total_amount:    number
  currency:        string
  recipient_count: number
  status:          'draft' | 'processing' | 'completed' | 'failed'
  dest_chain:      string
  executed_at:     number | null
  created_at:      number
  recipients?:     PayrollRecipient[]
}

export function usePayrollBatches() {
  const { address } = useAccount()
  return useQuery<PayrollBatch[]>({
    queryKey: ['payroll-batches', address],
    queryFn:  async () => {
      if (!address) return []
      const res = await fetch(`${API}/payroll/batches?wallet=${address}`)
      return res.ok ? res.json() : []
    },
    enabled: !!address,
  })
}

export function usePayrollBatch(id: string | null) {
  return useQuery<PayrollBatch | null>({
    queryKey: ['payroll-batch', id],
    queryFn:  async () => {
      if (!id) return null
      const res = await fetch(`${API}/payroll/batches/${id}`)
      return res.ok ? res.json() : null
    },
    enabled:         !!id,
    refetchInterval: 3000,
  })
}

export function useCreateBatch() {
  const queryClient = useQueryClient()
  const { address } = useAccount()
  return useMutation({
    mutationFn: async (data: {
      name: string; description?: string; destChain?: string
      recipients: { name?: string; walletAddress: string; amount: number }[]
    }) => {
      const res = await fetch(`${API}/payroll/batches`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ walletAddress: address, ...data }),
      })
      return res.json()
    },
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ['payroll-batches', address] }),
  })
}

export function useUpdateRecipient() {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: async ({ id, status, txHash, batchId }: { id: string; status: string; txHash?: string; batchId: string }) => {
      await fetch(`${API}/payroll/recipients/${id}`, {
        method: 'PATCH',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ status, txHash }),
      })
    },
    onSuccess: (_d, vars) => queryClient.invalidateQueries({ queryKey: ['payroll-batch', vars.batchId] }),
  })
}
AFX_FIX_EOF
echo "  ✓ afrifx-web/hooks/usePayroll.ts"
echo ""
echo "→ Done. Now re-run:"
echo "    cd afrifx-web && npx tsc --noEmit && npm run build"
echo ""
