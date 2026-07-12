'use client'
import { useQuery } from '@tanstack/react-query'
import { Wrench, AlertTriangle } from 'lucide-react'

const API = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'

export interface MaintenanceSection {
  section: string
  enabled: boolean
  message: string | null
  eta:     string | null
}

interface MaintenanceStatus {
  platformDown:   boolean
  platform:       MaintenanceSection | null
  sections:       MaintenanceSection[]
  defaultMessage: string
}

async function fetchStatus(): Promise<MaintenanceStatus> {
  const res = await fetch(`${API}/maintenance/status`)
  if (!res.ok) throw new Error('failed')
  return res.json()
}

export function useMaintenance() {
  return useQuery<MaintenanceStatus>({
    queryKey: ['maintenance'],
    queryFn:  fetchStatus,
    refetchInterval: 30_000,
    staleTime: 15_000,
    // Fail open — if this check errors, don't lock people out of the app.
    retry: 1,
  })
}

// Is a given section down (or the whole platform)?
export function useSectionDown(section: string) {
  const { data } = useMaintenance()
  if (!data) return null
  if (data.platformDown) return data.platform
  return data.sections.find(s => s.section === section) ?? null
}

/*
  Full-page state for a section that's offline. Shown INSTEAD of the feature,
  so nobody starts something that would fail.
*/
export function MaintenanceGate({
  down, defaultMessage,
}: { down: MaintenanceSection; defaultMessage?: string }) {
  return (
    <div className="flex min-h-[400px] items-center justify-center px-4">
      <div className="w-full max-w-md rounded-2xl border border-amber-500/40 bg-amber-500/[0.06] p-8 text-center">
        <span className="mx-auto mb-4 inline-flex h-12 w-12 items-center justify-center rounded-2xl bg-amber-500/15">
          <Wrench className="h-6 w-6 text-amber-400" />
        </span>
        <h2 className="text-lg font-semibold text-app-text">
          Temporarily unavailable
        </h2>
        <p className="mt-2 text-sm leading-relaxed text-app-muted">
          {down.message?.trim() || defaultMessage ||
            'This section is temporarily unavailable while we perform a scheduled upgrade.'}
        </p>
        {down.eta && (
          <p className="mt-3 inline-block rounded-lg bg-app-surface px-3 py-1.5 text-xs text-app-text">
            Expected back: {down.eta}
          </p>
        )}
        <p className="mt-4 border-t border-amber-500/20 pt-3 text-xs text-app-muted">
          Trades already in progress are unaffected — you can still confirm,
          cancel, and message on them.
        </p>
      </div>
    </div>
  )
}

/*
  A slim banner for when the WHOLE platform is under maintenance. Shown at the
  top of the app so it's visible everywhere.
*/
export function PlatformMaintenanceBanner() {
  const { data } = useMaintenance()
  if (!data?.platformDown || !data.platform) return null
  const m = data.platform
  return (
    <div className="flex items-start gap-2.5 border-b border-amber-500/30 bg-amber-500/[0.08] px-4 py-2.5">
      <AlertTriangle className="mt-0.5 h-4 w-4 shrink-0 text-amber-400" />
      <p className="text-xs text-app-text">
        <span className="font-medium">Scheduled maintenance.</span>{' '}
        {m.message?.trim() || data.defaultMessage}
        {m.eta && <span className="text-app-muted"> · Expected back: {m.eta}</span>}
      </p>
    </div>
  )
}
