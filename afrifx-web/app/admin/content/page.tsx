'use client'
import { useState, useEffect } from 'react'
import { AdminShell } from '@/components/admin/AdminShell'
import { adminFetch, useAdminAuth } from '@/hooks/useAdminAuth'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Card, CardHeader, CardTitle, CardContent } from '@/components/ui/card'
import {
  Loader2, Plus, Trash2, ArrowUp, ArrowDown,
  CheckCircle, AlertCircle, FileText, Mail,
} from 'lucide-react'

interface Section { heading: string; body: string }
interface Contact {
  email: string; phone: string; address: string; supportHours: string
  twitter: string; telegram: string; discord: string
}

const EMPTY_CONTACT: Contact = {
  email: '', phone: '', address: '', supportHours: '',
  twitter: '', telegram: '', discord: '',
}

export default function AdminContentPage() {
  const { hasPermission } = useAdminAuth()
  const canEdit = hasPermission('manage_content')

  const [sections, setSections] = useState<Section[]>([])
  const [contact,  setContact]  = useState<Contact>(EMPTY_CONTACT)
  const [loading,  setLoading]  = useState(true)

  const [savingAbout,   setSavingAbout]   = useState(false)
  const [savingContact, setSavingContact] = useState(false)
  const [aboutMsg,   setAboutMsg]   = useState<{ ok: boolean; text: string } | null>(null)
  const [contactMsg, setContactMsg] = useState<{ ok: boolean; text: string } | null>(null)

  useEffect(() => {
    Promise.all([
      adminFetch('/content/about').then(r => r.json()).catch(() => ({ sections: [] })),
      adminFetch('/content/contact').then(r => r.json()).catch(() => ({ contact: EMPTY_CONTACT })),
    ]).then(([a, c]) => {
      setSections(Array.isArray(a.sections) ? a.sections : [])
      setContact({ ...EMPTY_CONTACT, ...(c.contact ?? {}) })
    }).finally(() => setLoading(false))
  }, [])

  // ── About section editing ────────────────────────────────
  function updateSection(i: number, field: keyof Section, val: string) {
    setSections(prev => prev.map((s, idx) => idx === i ? { ...s, [field]: val } : s))
  }
  function addSection() {
    setSections(prev => [...prev, { heading: '', body: '' }])
  }
  function removeSection(i: number) {
    setSections(prev => prev.filter((_, idx) => idx !== i))
  }
  function moveSection(i: number, dir: -1 | 1) {
    setSections(prev => {
      const next = [...prev]
      const j = i + dir
      if (j < 0 || j >= next.length) return prev
      ;[next[i], next[j]] = [next[j], next[i]]
      return next
    })
  }

  async function saveAbout() {
    setAboutMsg(null); setSavingAbout(true)
    try {
      const res = await adminFetch('/content/about', {
        method: 'PATCH', body: JSON.stringify({ sections }),
      })
      const data = await res.json().catch(() => ({}))
      if (res.ok) {
        setSections(data.sections ?? sections)
        setAboutMsg({ ok: true, text: 'About page saved' })
      } else {
        setAboutMsg({ ok: false, text: data.error ?? 'Could not save' })
      }
    } finally { setSavingAbout(false) }
  }

  async function saveContact() {
    setContactMsg(null); setSavingContact(true)
    try {
      const res = await adminFetch('/content/contact', {
        method: 'PATCH', body: JSON.stringify({ contact }),
      })
      const data = await res.json().catch(() => ({}))
      if (res.ok) {
        setContact({ ...EMPTY_CONTACT, ...(data.contact ?? contact) })
        setContactMsg({ ok: true, text: 'Contact details saved' })
      } else {
        setContactMsg({ ok: false, text: data.error ?? 'Could not save' })
      }
    } finally { setSavingContact(false) }
  }

  if (loading) {
    return (
      <AdminShell>
        <div className="flex justify-center py-16"><Loader2 className="h-6 w-6 animate-spin text-app-accent" /></div>
      </AdminShell>
    )
  }

  if (!canEdit) {
    return (
      <AdminShell>
        <div className="mx-auto max-w-md rounded-xl border border-app-border bg-app-surface p-6 text-center">
          <AlertCircle className="mx-auto mb-2 h-6 w-6 text-app-muted" />
          <p className="text-sm text-app-text">You don't have permission to edit site content.</p>
        </div>
      </AdminShell>
    )
  }

  const contactFields: { key: keyof Contact; label: string; placeholder: string }[] = [
    { key: 'email',        label: 'Support email', placeholder: 'support@afrifx.xyz' },
    { key: 'phone',        label: 'Phone',         placeholder: '+234 …' },
    { key: 'address',      label: 'Address',       placeholder: 'Office address' },
    { key: 'supportHours', label: 'Support hours', placeholder: 'Mon–Fri, 9am–5pm WAT' },
    { key: 'twitter',      label: 'Twitter / X',   placeholder: 'https://x.com/afrifx' },
    { key: 'telegram',     label: 'Telegram',      placeholder: 'https://t.me/…' },
    { key: 'discord',      label: 'Discord',       placeholder: 'https://discord.gg/…' },
  ]

  return (
    <AdminShell>
      <div className="mx-auto max-w-3xl space-y-6">
        <div>
          <h1 className="text-lg font-semibold text-app-text">Site content</h1>
          <p className="text-sm text-app-muted">Edit the public About and Contact pages.</p>
        </div>

        {/* About editor */}
        <Card>
          <CardHeader>
            <CardTitle className="flex items-center gap-2">
              <FileText className="h-4 w-4 text-app-accent-text" /> About page
            </CardTitle>
          </CardHeader>
          <CardContent className="space-y-4">
            {sections.length === 0 && (
              <p className="text-sm text-app-muted">No sections yet, add one below.</p>
            )}
            {sections.map((s, i) => (
              <div key={i} className="rounded-lg border border-app-border bg-app-bg p-3">
                <div className="mb-2 flex items-center justify-between">
                  <span className="text-xs text-app-muted">Section {i + 1}</span>
                  <div className="flex items-center gap-1">
                    <button onClick={() => moveSection(i, -1)} disabled={i === 0}
                      className="rounded p-1 text-app-muted hover:text-app-text disabled:opacity-30" title="Move up">
                      <ArrowUp className="h-3.5 w-3.5" />
                    </button>
                    <button onClick={() => moveSection(i, 1)} disabled={i === sections.length - 1}
                      className="rounded p-1 text-app-muted hover:text-app-text disabled:opacity-30" title="Move down">
                      <ArrowDown className="h-3.5 w-3.5" />
                    </button>
                    <button onClick={() => removeSection(i)}
                      className="rounded p-1 text-app-muted hover:text-red-400" title="Remove">
                      <Trash2 className="h-3.5 w-3.5" />
                    </button>
                  </div>
                </div>
                <Input className="mb-2" placeholder="Heading"
                  value={s.heading} onChange={e => updateSection(i, 'heading', e.target.value)} />
                <textarea
                  className="min-h-[90px] w-full resize-y rounded-md border border-app-border bg-app-bg px-3 py-2 text-sm text-app-text placeholder:text-app-muted focus:outline-none focus:ring-1 focus:ring-app-accent"
                  placeholder="Body text"
                  value={s.body} onChange={e => updateSection(i, 'body', e.target.value)} />
              </div>
            ))}

            <div className="flex flex-wrap items-center gap-2">
              <Button variant="outline" size="sm" onClick={addSection}>
                <Plus className="h-4 w-4" /> Add section
              </Button>
              <Button size="sm" onClick={saveAbout} disabled={savingAbout}>
                {savingAbout ? <><Loader2 className="h-4 w-4 animate-spin" /> Saving…</> : 'Save About page'}
              </Button>
            </div>
            {aboutMsg && (
              <div className={`flex items-center gap-2 rounded-lg px-3 py-2 text-xs ${aboutMsg.ok ? 'bg-emerald-900/20 text-emerald-400' : 'bg-red-900/20 text-red-400'}`}>
                {aboutMsg.ok ? <CheckCircle className="h-3.5 w-3.5" /> : <AlertCircle className="h-3.5 w-3.5" />}
                {aboutMsg.text}
              </div>
            )}
          </CardContent>
        </Card>

        {/* Contact editor */}
        <Card>
          <CardHeader>
            <CardTitle className="flex items-center gap-2">
              <Mail className="h-4 w-4 text-app-accent-text" /> Contact page
            </CardTitle>
          </CardHeader>
          <CardContent className="space-y-3">
            {contactFields.map(({ key, label, placeholder }) => (
              <div key={key}>
                <label className="mb-1 block text-xs text-app-muted">{label}</label>
                <Input placeholder={placeholder}
                  value={contact[key]} onChange={e => setContact({ ...contact, [key]: e.target.value })} />
              </div>
            ))}
            <div className="pt-1">
              <Button size="sm" onClick={saveContact} disabled={savingContact}>
                {savingContact ? <><Loader2 className="h-4 w-4 animate-spin" /> Saving…</> : 'Save Contact details'}
              </Button>
            </div>
            {contactMsg && (
              <div className={`flex items-center gap-2 rounded-lg px-3 py-2 text-xs ${contactMsg.ok ? 'bg-emerald-900/20 text-emerald-400' : 'bg-red-900/20 text-red-400'}`}>
                {contactMsg.ok ? <CheckCircle className="h-3.5 w-3.5" /> : <AlertCircle className="h-3.5 w-3.5" />}
                {contactMsg.text}
              </div>
            )}
          </CardContent>
        </Card>
      </div>
    </AdminShell>
  )
}
