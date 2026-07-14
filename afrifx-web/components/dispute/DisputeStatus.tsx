'use client'
import { useEffect, useState } from 'react'
import { Scale, Loader2 } from 'lucide-react'
import { DisputeChat } from './DisputeChat'
import { useProfileByAddress } from '@/hooks/useProfile'

const API = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'

interface Assignment {
  admin_name:  string
  accepted_at: number
}

interface Props {
  disputeId:   string
  offerId:     string
  userAddress: string
  userRole:    'maker' | 'taker'
  username?:   string
}

export function DisputeStatus({ disputeId, offerId, userAddress, userRole, username }: Props) {
  // Resolve the viewer's own @username so messages they send carry it, rather
  // than a truncated wallet address.
  const { data: myProfile } = useProfileByAddress(userAddress)
  const resolvedName = username ?? myProfile?.username ?? userAddress.slice(0, 8)
  const [assignment, setAssignment] = useState<Assignment | null>(null)
  const [loading,    setLoading]    = useState(true)

  async function fetchAssignment() {
    try {
      const res  = await fetch(`${API}/disputes/${disputeId}/assignment`)
      const data = await res.json()
      setAssignment(data ?? null)
    } catch {}
    finally { setLoading(false) }
  }

  useEffect(() => {
    if (!disputeId) { setLoading(false); return }
    fetchAssignment()
    // Poll every 15s to detect when admin accepts
    const interval = setInterval(fetchAssignment, 15_000)
    return () => clearInterval(interval)
  }, [disputeId])

  if (!disputeId) return (
    <div className="rounded-lg border border-amber-900/40 bg-amber-900/10 p-3 text-xs">
      <p className="font-medium text-amber-400">⏳ Dispute raised, awaiting admin review</p>
      <p className="mt-1 text-amber-600">An admin will accept and handle your dispute shortly.</p>
    </div>
  )

  if (loading) return (
    <div className="flex items-center gap-2 rounded-lg bg-app-bg p-3 text-xs text-app-muted">
      <Loader2 className="h-3.5 w-3.5 animate-spin" />
      Checking dispute status…
    </div>
  )

  return (
    <div className="space-y-3">
      {/* Assignment status */}
      <div className={`rounded-lg border p-3 text-xs
        ${assignment
          ? 'border-emerald-900/40 bg-emerald-900/10'
          : 'border-amber-900/40 bg-amber-900/10'}`}>
        <div className="flex items-start gap-2">
          <Scale className={`h-4 w-4 mt-0.5 shrink-0 ${assignment ? 'text-emerald-400' : 'text-amber-400'}`} />
          <div>
            {assignment ? (
              <>
                <p className="font-medium text-emerald-400">
                  Admin {assignment.admin_name} has accepted your dispute
                </p>
                <p className="mt-0.5 text-emerald-600">
                  They will review the evidence and contact you below.
                  Upload your bank statement when requested.
                </p>
              </>
            ) : (
              <>
                <p className="font-medium text-amber-400">Dispute under review</p>
                <p className="mt-0.5 text-amber-600">
                  An admin will accept and handle your dispute shortly.
                </p>
              </>
            )}
          </div>
        </div>
      </div>

      {/* Chat only visible after admin accepts */}
      {assignment && disputeId && (
        <DisputeChat
          disputeId={disputeId}
          senderId={userAddress}
          senderType={userRole}
          senderName={resolvedName}
          viewerType="user"
          title={`Chat with Admin ${assignment.admin_name}`}
        />
      )}
    </div>
  )
}
