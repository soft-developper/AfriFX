'use client'
import { useState } from 'react'
import { useAccount } from 'wagmi'
import Link from 'next/link'
import { useRouter } from 'next/navigation'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Badge } from '@/components/ui/badge'
import { useWallet } from '@/hooks/useWallet'
import { usePayrollBatches } from '@/hooks/usePayroll'
import { useTreasuryRules, useCreateRule, useToggleRule, useDeleteRule } from '@/hooks/useTreasury'
import { useFXRates } from '@/hooks/useFXRate'
import { formatAmount } from '@/lib/utils'
import {
  Plus, Zap, Trash2, Pause, Play,
  AlertTriangle, ArrowRight, Users, Building2,
  ChevronDown, ChevronUp, ExternalLink,
} from 'lucide-react'

const CURRENCIES  = ['NGN','GHS','KES','ZAR','EGP']
const CURRENCY_FLAG: Record<string, string> = {
  NGN:'🇳🇬',GHS:'🇬🇭',KES:'🇰🇪',ZAR:'🇿🇦',EGP:'🇪🇬'
}

export function TreasuryContent() {
  const { address }               = useAccount()
  const router                    = useRouter()
  const { data: wallet }          = useWallet()
  const { data: rules = [] }      = useTreasuryRules()
  const { data: batches = [] }    = usePayrollBatches()
  const { data: rates = [] }      = useFXRates()
  const createRule                = useCreateRule()
  const toggleRule                = useToggleRule()
  const deleteRule                = useDeleteRule()

  const [showRuleForm, setShowRuleForm] = useState(false)
  const [ruleName,     setRuleName]     = useState('')
  const [threshold,    setThreshold]    = useState('')
  const [actionType,   setActionType]   = useState<'percent'|'fixed'>('percent')
  const [actionVal,    setActionVal]    = useState('')
  const [targetCcy,    setTargetCcy]    = useState('NGN')

  const usdcBalance = wallet?.tokens.find(t => t.symbol === 'USDC')?.balance ?? 0
  const escrowLocked = wallet?.escrow.locked ?? 0
  const triggeredRules = rules.filter(r => r.status === 'triggered')

  async function handleCreateRule() {
    if (!ruleName || !threshold || !actionVal) return
    await createRule.mutateAsync({
      name:              ruleName,
      trigger_threshold: parseFloat(threshold),
      action_percent:    actionType === 'percent' ? parseFloat(actionVal) : null,
      action_amount:     actionType === 'fixed'   ? parseFloat(actionVal) : null,
      target_currency:   targetCcy,
    })
    setRuleName(''); setThreshold(''); setActionVal('')
    setShowRuleForm(false)
  }

  function getConversionAmount(rule: typeof rules[0]): number {
    if (rule.action_percent) return usdcBalance * (rule.action_percent / 100)
    return rule.action_amount ?? 0
  }

  function getLocalEquiv(usdcAmt: number, currency: string): string {
    const rate = rates.find(r => r.pair === `${currency}/USDC`)?.rate
    if (!rate) return '—'
    return (usdcAmt / rate).toLocaleString(undefined, { maximumFractionDigits: 0 })
  }

  return (
    <div>
      {/* Header */}
      <div className="mb-6 flex items-center justify-between">
        <div>
          <h1 className="text-xl font-semibold text-app-text">Business Treasury</h1>
          <p className="text-sm text-app-muted">Automate conversions · manage payroll · track funds</p>
        </div>
        <Link href="/treasury/payroll">
          <Button size="sm">
            <Users className="h-4 w-4" /> New payroll
          </Button>
        </Link>
      </div>

      {/* Triggered rules alert */}
      {triggeredRules.length > 0 && (
        <div className="mb-4 rounded-xl border border-amber-900/50 bg-amber-900/20 p-4">
          <div className="flex items-start gap-3">
            <AlertTriangle className="mt-0.5 h-5 w-5 shrink-0 text-amber-400" />
            <div className="flex-1">
              <p className="text-sm font-medium text-amber-400">
                {triggeredRules.length} auto-conversion rule{triggeredRules.length > 1 ? 's' : ''} triggered
              </p>
              {triggeredRules.map(r => {
                const amt = getConversionAmount(r)
                return (
                  <div key={r.id} className="mt-2 flex items-center justify-between text-xs">
                    <span className="text-amber-600">
                      "{r.name}" — convert {r.action_percent ? `${r.action_percent}%` : `${r.action_amount} USDC`} to {r.target_currency}
                      {amt > 0 && ` (≈ ${getLocalEquiv(amt, r.target_currency)} ${r.target_currency})`}
                    </span>
                    <div className="flex gap-2">
                      <Link href="/convert">
                        <Button size="sm" className="h-7 text-xs">
                          Convert now <ArrowRight className="h-3 w-3" />
                        </Button>
                      </Link>
                      <Button size="sm" variant="outline" className="h-7 text-xs"
                        onClick={() => toggleRule.mutate({ id: r.id, status: 'active' })}>
                        Dismiss
                      </Button>
                    </div>
                  </div>
                )
              })}
            </div>
          </div>
        </div>
      )}

      {/* Stats row */}
      <div className="mb-6 grid grid-cols-1 gap-3 sm:grid-cols-2 lg:grid-cols-4">
        {[
          { label: 'Available USDC',   value: `$${formatAmount(usdcBalance)}`,  sub: 'ready to use'        },
          { label: 'In escrow',        value: `$${formatAmount(escrowLocked)}`, sub: 'locked in P2P offers' },
          { label: 'Active rules',     value: String(rules.filter(r => r.status === 'active').length),
            sub: 'auto-conversion rules' },
          { label: 'Payrolls run',     value: String(batches.filter(b => b.status === 'completed').length),
            sub: `$${formatAmount(batches.filter(b => b.status === 'completed').reduce((s,b) => s + b.total_amount, 0))} total paid` },
        ].map(({ label, value, sub }) => (
          <div key={label} className="rounded-xl border border-app-border bg-app-surface p-4">
            <p className="text-xs text-app-muted">{label}</p>
            <p className="mt-1 font-mono text-xl font-semibold text-app-text">{value}</p>
            <p className="mt-0.5 text-xs text-app-muted">{sub}</p>
          </div>
        ))}
      </div>

      <div className="grid gap-4 grid-cols-1 lg:grid-cols-2">

        {/* Auto-conversion rules */}
        <div className="rounded-xl border border-app-border bg-app-surface p-5">
          <div className="mb-4 flex items-center justify-between">
            <div>
              <p className="text-sm font-medium text-app-text">Auto-conversion rules</p>
              <p className="text-xs text-app-muted">Trigger when USDC balance crosses a threshold</p>
            </div>
            <Button size="sm" variant="outline"
              onClick={() => setShowRuleForm(!showRuleForm)}>
              <Plus className="h-3.5 w-3.5" /> New rule
            </Button>
          </div>

          {/* Create rule form */}
          {showRuleForm && (
            <div className="mb-4 space-y-3 rounded-xl border border-app-border bg-app-bg p-4">
              <p className="text-xs font-medium text-app-text">New rule</p>
              <Input placeholder="Rule name (e.g. Convert excess NGN)"
                value={ruleName} onChange={e => setRuleName(e.target.value)} />
              <div className="flex gap-2">
                <div className="flex-1">
                  <p className="mb-1 text-[10px] text-app-muted">When USDC balance exceeds</p>
                  <Input type="number" placeholder="1000" value={threshold}
                    onChange={e => setThreshold(e.target.value)} />
                </div>
                <div className="flex-1">
                  <p className="mb-1 text-[10px] text-app-muted">Target currency</p>
                  <select value={targetCcy} onChange={e => setTargetCcy(e.target.value)}
                    className="w-full rounded-lg border border-app-border bg-app-surface px-3 py-2 text-sm text-app-text outline-none">
                    {CURRENCIES.map(c => (
                      <option key={c} value={c}>{CURRENCY_FLAG[c]} {c}</option>
                    ))}
                  </select>
                </div>
              </div>
              <div>
                <p className="mb-1 text-[10px] text-app-muted">Convert</p>
                <div className="flex gap-2">
                  <div className="flex rounded-lg border border-app-border bg-app-surface">
                    {(['percent','fixed'] as const).map(t => (
                      <button key={t} onClick={() => setActionType(t)}
                        className={`px-3 py-1.5 text-xs transition-colors rounded-lg
                          ${actionType === t ? 'bg-app-accent text-app-on-accent' : 'text-app-muted'}`}>
                        {t === 'percent' ? '%' : 'Fixed'}
                      </button>
                    ))}
                  </div>
                  <Input type="number"
                    placeholder={actionType === 'percent' ? '30 (%)' : 'Amount (USDC)'}
                    value={actionVal} onChange={e => setActionVal(e.target.value)}
                    className="flex-1" />
                </div>
              </div>
              <div className="flex gap-2">
                <Button size="sm" variant="outline" className="flex-1"
                  onClick={() => setShowRuleForm(false)}>Cancel</Button>
                <Button size="sm" className="flex-1" onClick={handleCreateRule}
                  disabled={createRule.isPending || !ruleName || !threshold || !actionVal}>
                  {createRule.isPending ? 'Saving…' : 'Save rule'}
                </Button>
              </div>
            </div>
          )}

          {/* Rules list */}
          {rules.length === 0 ? (
            <div className="flex flex-col items-center gap-2 py-8 text-center">
              <Zap className="h-8 w-8 text-app-border" />
              <p className="text-sm text-app-muted">No rules yet</p>
              <p className="text-xs text-app-muted">
                Create a rule to be alerted when your balance crosses a threshold
              </p>
            </div>
          ) : (
            <div className="space-y-2">
              {rules.map(rule => {
                const amt = getConversionAmount(rule)
                return (
                  <div key={rule.id}
                    className="rounded-xl border border-app-border bg-app-bg p-3">
                    <div className="flex items-start justify-between gap-2">
                      <div className="flex-1 min-w-0">
                        <div className="flex items-center gap-2">
                          <p className="text-sm font-medium text-app-text truncate">{rule.name}</p>
                          <Badge variant={
                            rule.status === 'triggered' ? 'warning' :
                            rule.status === 'active'    ? 'success'  : 'default'
                          }>
                            {rule.status}
                          </Badge>
                        </div>
                        <p className="mt-0.5 text-xs text-app-muted">
                          When USDC &gt; {rule.trigger_threshold.toLocaleString()} →{' '}
                          convert {rule.action_percent ? `${rule.action_percent}%` : `${rule.action_amount} USDC`} to{' '}
                          {CURRENCY_FLAG[rule.target_currency]} {rule.target_currency}
                        </p>
                        {rule.last_triggered && (
                          <p className="mt-0.5 text-[10px] text-amber-500">
                            Last triggered: {new Date(rule.last_triggered * 1000).toLocaleDateString()}
                          </p>
                        )}
                      </div>
                      <div className="flex items-center gap-1 shrink-0">
                        <button
                          onClick={() => toggleRule.mutate({
                            id: rule.id,
                            status: rule.status === 'active' ? 'paused' : 'active',
                          })}
                          className="rounded p-1.5 text-app-muted hover:text-app-text transition-colors"
                          title={rule.status === 'active' ? 'Pause' : 'Activate'}
                        >
                          {rule.status === 'active'
                            ? <Pause className="h-3.5 w-3.5" />
                            : <Play  className="h-3.5 w-3.5" />
                          }
                        </button>
                        <button
                          onClick={() => deleteRule.mutate(rule.id)}
                          className="rounded p-1.5 text-app-muted hover:text-red-400 transition-colors"
                          title="Delete rule"
                        >
                          <Trash2 className="h-3.5 w-3.5" />
                        </button>
                      </div>
                    </div>
                  </div>
                )
              })}
            </div>
          )}
        </div>

        {/* Recent payrolls */}
        <div className="rounded-xl border border-app-border bg-app-surface p-5">
          <div className="mb-4 flex items-center justify-between">
            <div>
              <p className="text-sm font-medium text-app-text">Recent payrolls</p>
              <p className="text-xs text-app-muted">Batch USDC payments with Memo references</p>
            </div>
            <Link href="/treasury/payroll">
              <Button size="sm" variant="outline">
                <Plus className="h-3.5 w-3.5" /> New batch
              </Button>
            </Link>
          </div>

          {batches.length === 0 ? (
            <div className="flex flex-col items-center gap-2 py-8 text-center">
              <Building2 className="h-8 w-8 text-app-border" />
              <p className="text-sm text-app-muted">No payrolls yet</p>
              <p className="text-xs text-app-muted">
                Send USDC to multiple wallets in one batch with unique Memo references
              </p>
              <Link href="/treasury/payroll">
                <Button size="sm" variant="outline" className="mt-2">Create first payroll</Button>
              </Link>
            </div>
          ) : (
            <div className="space-y-2">
              {batches.slice(0, 6).map(batch => (
                <Link key={batch.id} href={`/treasury/payroll/${batch.id}`}>
                  <div className="flex items-center justify-between rounded-xl border border-app-border bg-app-bg p-3 hover:border-app-accent/40 transition-colors cursor-pointer">
                    <div className="flex-1 min-w-0">
                      <div className="flex items-center gap-2">
                        <p className="text-sm font-medium text-app-text truncate">{batch.name}</p>
                        <Badge variant={
                          batch.status === 'completed'  ? 'success' :
                          batch.status === 'processing' ? 'arc'     :
                          batch.status === 'failed'     ? 'danger'  : 'warning'
                        }>
                          {batch.status}
                        </Badge>
                      </div>
                      <p className="text-xs text-app-muted">
                        {batch.recipient_count} recipients · ${formatAmount(batch.total_amount)} USDC
                        · {new Date(batch.created_at * 1000).toLocaleDateString()}
                      </p>
                    </div>
                    <ArrowRight className="h-4 w-4 shrink-0 text-app-muted" />
                  </div>
                </Link>
              ))}
            </div>
          )}
        </div>
      </div>
    </div>
  )
}
