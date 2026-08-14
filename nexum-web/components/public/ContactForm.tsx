'use client'
import { useState } from 'react'
import { Send, Loader2, CheckCircle, AlertCircle } from 'lucide-react'

const API = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'

export function ContactForm() {
  const [name,    setName]    = useState('')
  const [email,   setEmail]   = useState('')
  const [subject, setSubject] = useState('')
  const [message, setMessage] = useState('')
  const [busy,    setBusy]    = useState(false)
  const [sent,    setSent]    = useState(false)
  const [error,   setError]   = useState<string | null>(null)

  async function submit() {
    setError(null)
    if (!name || !email || !message) { setError('Name, email and message are required.'); return }
    setBusy(true)
    try {
      const res = await fetch(`${API}/content/contact/message`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ name, email, subject, message }),
      })
      const data = await res.json().catch(() => ({}))
      if (res.ok) {
        setSent(true)
        setName(''); setEmail(''); setSubject(''); setMessage('')
      } else {
        setError(data.error ?? 'Could not send your message. Please try again.')
      }
    } catch {
      setError('Could not send your message. Please check your connection.')
    } finally { setBusy(false) }
  }

  if (sent) {
    return (
      <div className="flex flex-col items-center gap-3 rounded-2xl border border-app-border bg-app-surface p-8 text-center">
        <CheckCircle className="h-8 w-8 text-emerald-400" />
        <p className="font-medium text-app-text">Thanks for reaching out</p>
        <p className="text-sm text-app-muted">We've received your message and will get back to you soon.</p>
        <button onClick={() => setSent(false)}
          className="mt-2 text-sm font-medium text-app-accent-text hover:underline">
          Send another message
        </button>
      </div>
    )
  }

  const inputCls = 'w-full rounded-lg border border-app-border bg-app-bg px-3 py-2 text-sm text-app-text placeholder:text-app-muted focus:outline-none focus:ring-1 focus:ring-app-accent'

  return (
    <div className="rounded-2xl border border-app-border bg-app-surface p-6">
      <h2 className="mb-4 text-lg font-semibold text-app-text">Send us a message</h2>
      <div className="space-y-3">
        <div className="grid gap-3 sm:grid-cols-2">
          <input className={inputCls} placeholder="Your name"
            value={name} onChange={e => setName(e.target.value)} />
          <input className={inputCls} type="email" placeholder="Your email"
            value={email} onChange={e => setEmail(e.target.value)} />
        </div>
        <input className={inputCls} placeholder="Subject (optional)"
          value={subject} onChange={e => setSubject(e.target.value)} />
        <textarea className={`${inputCls} min-h-[140px] resize-y`} placeholder="How can we help?"
          value={message} onChange={e => setMessage(e.target.value)} />

        <button onClick={submit} disabled={busy}
          className="inline-flex items-center gap-2 rounded-lg bg-app-accent px-4 py-2 text-sm font-medium text-app-on-accent transition-colors hover:bg-app-accent-hover disabled:opacity-50">
          {busy ? <><Loader2 className="h-4 w-4 animate-spin" /> Sending…</> : <><Send className="h-4 w-4" /> Send message</>}
        </button>

        {error && (
          <div className="flex items-start gap-2 rounded-lg bg-red-900/20 px-3 py-2.5 text-xs text-red-400">
            <AlertCircle className="mt-0.5 h-3.5 w-3.5 shrink-0" />{error}
          </div>
        )}
      </div>
    </div>
  )
}
