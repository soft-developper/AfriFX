'use client'
import { useState } from 'react'
import { Sparkles, Loader2, RefreshCw, ShieldAlert, AlertCircle } from 'lucide-react'
import { adminFetch } from '@/hooks/useAdminAuth'

interface DisputeSummary {
  timeline:        string
  maker_position:  string
  taker_position:  string
  divergence:      string
  onchain_facts:   string
  evidence_notes:  string
  missing:         string
  injection_flags: string
}

interface Props {
  disputeId: string
  adminId:   string
}

// Advisory AI brief for the assigned admin. It SUMMARISES; the admin still
// decides. Rendered as plain text — it can trigger no action.
export function AiSummaryPanel({ disputeId, adminId }: Props) {
  const [summary,   setSummary]   = useState<DisputeSummary | null>(null)
  const [meta,      setMeta]      = useState<{ model?: string; evidenceCount?: number; createdAt?: number; cached?: boolean } | null>(null)
  const [loading,   setLoading]   = useState(false)
  const [error,     setError]     = useState<string | null>(null)
  const [notConfigured, setNotConfigured] = useState(false)

  async function generate(refresh = false) {
    setLoading(true)
    setError(null)
    try {
      const res = await adminFetch(
        `/disputes/${disputeId}/ai-summary${refresh ? '?refresh=1' : ''}`,
        { method: 'POST', body: JSON.stringify({ adminId }) },
      )
      const data = await res.json()
      if (!res.ok) {
        if (data.code === 'ai_not_configured') { setNotConfigured(true); return }
        setError(data.error ?? 'Failed to generate summary')
        return
      }
      setSummary(data.summary)
      setMeta({ model: data.model, evidenceCount: data.evidenceCount, createdAt: data.createdAt, cached: data.cached })
    } catch (err: any) {
      setError(err.message ?? 'Failed to generate summary')
    } finally {
      setLoading(false)
    }
  }

  if (notConfigured) {
    return (
      <div className="rounded-lg border border-app-border bg-app-bg p-3 text-xs text-app-muted">
        AI summary isn’t enabled on this server.
      </div>
    )
  }

  const flagged =
    summary && summary.injection_flags &&
    summary.injection_flags.trim().toLowerCase() !== 'none detected.' &&
    summary.injection_flags.trim() !== ''

  const sections: [string, string][] = summary ? [
    ['What happened',      summary.timeline],
    ['Seller’s position',  summary.maker_position],
    ['Buyer’s position',   summary.taker_position],
    ['Where they diverge', summary.divergence],
    ['On-chain record',    summary.onchain_facts],
    ['Evidence',           summary.evidence_notes],
    ['What’s missing',     summary.missing],
  ] : []

  return (
    <div className="rounded-lg border border-app-accent/30 bg-app-accent/5 p-4">
      <div className="mb-2 flex items-center justify-between">
        <span className="flex items-center gap-1.5 text-xs font-semibold text-app-accent-text">
          <Sparkles className="h-3.5 w-3.5" /> AI case summary
        </span>
        {summary && (
          <button
            onClick={() => generate(true)}
            disabled={loading}
            className="flex items-center gap-1 text-xs text-app-muted hover:text-app-accent-text"
          >
            <RefreshCw className={`h-3 w-3 ${loading ? 'animate-spin' : ''}`} /> Regenerate
          </button>
        )}
      </div>

      {/* Always-on disclaimer */}
      <p className="mb-3 flex items-start gap-1 text-[11px] leading-snug text-app-muted">
        <AlertCircle className="mt-0.5 h-3 w-3 shrink-0" />
        AI-generated and can be wrong. Read it as a starting point, then verify against the
        evidence and chat before deciding. It does not make the decision.
      </p>

      {!summary && !loading && (
        <button
          onClick={() => generate(false)}
          className="flex items-center gap-1.5 rounded-md bg-app-accent px-3 py-1.5 text-xs font-medium text-white hover:opacity-90"
        >
          <Sparkles className="h-3.5 w-3.5" /> Generate summary
        </button>
      )}

      {loading && !summary && (
        <div className="flex items-center gap-2 py-2 text-xs text-app-muted">
          <Loader2 className="h-3.5 w-3.5 animate-spin" /> Reading the case and evidence…
        </div>
      )}

      {error && (
        <div className="rounded-md bg-red-900/20 px-3 py-2 text-xs text-red-400">{error}</div>
      )}

      {summary && (
        <div className="space-y-2.5">
          {/* Injection warning — surfaced, never obeyed */}
          {flagged && (
            <div className="rounded-md border border-amber-700/50 bg-amber-900/20 p-2.5">
              <p className="mb-1 flex items-center gap-1 text-xs font-semibold text-amber-400">
                <ShieldAlert className="h-3.5 w-3.5" /> Possible manipulation attempt
              </p>
              <p className="text-[11px] leading-snug text-amber-200/90">{summary.injection_flags}</p>
              <p className="mt-1 text-[10px] text-amber-200/60">
                Text in the chat or evidence tried to instruct the AI. It was ignored and flagged here.
              </p>
            </div>
          )}

          {sections.map(([label, value]) => (
            <div key={label}>
              <p className="text-[11px] font-semibold uppercase tracking-wide text-app-muted">{label}</p>
              <p className="text-xs leading-relaxed text-app-text">{value || '—'}</p>
            </div>
          ))}

          {meta && (
            <p className="border-t border-app-border pt-2 text-[10px] text-app-muted">
              {meta.evidenceCount ? `${meta.evidenceCount} evidence PDF(s) read · ` : 'No evidence PDFs · '}
              {meta.model}
              {meta.cached ? ' · cached' : ''}
              {meta.createdAt ? ` · ${new Date(meta.createdAt * 1000).toLocaleString()}` : ''}
            </p>
          )}
        </div>
      )}
    </div>
  )
}
