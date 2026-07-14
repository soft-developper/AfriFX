import { Mail, Phone, MapPin, Clock, Twitter, Send as TelegramIcon, MessageCircle } from 'lucide-react'
import { PublicHeader, PublicFooter } from '@/components/public/PublicChrome'
import { ContactForm } from '@/components/public/ContactForm'

const API = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'

interface Contact {
  email?: string; phone?: string; address?: string; supportHours?: string
  twitter?: string; telegram?: string; discord?: string
}

async function getContact(): Promise<Contact> {
  try {
    const res = await fetch(`${API}/content/contact`, { next: { revalidate: 60 } })
    if (!res.ok) return {}
    const data = await res.json()
    return data.contact ?? {}
  } catch { return {} }
}

export const metadata = {
  title: 'Contact, AfriFX',
  description: 'Get in touch with the AfriFX team.',
}

export default async function ContactPage() {
  const c = await getContact()

  const details = [
    c.email        && { icon: Mail,   label: 'Email',         value: c.email,        href: `mailto:${c.email}` },
    c.phone        && { icon: Phone,  label: 'Phone',         value: c.phone,        href: `tel:${c.phone}` },
    c.address      && { icon: MapPin, label: 'Address',       value: c.address,      href: undefined },
    c.supportHours && { icon: Clock,  label: 'Support hours', value: c.supportHours, href: undefined },
  ].filter(Boolean) as { icon: any; label: string; value: string; href?: string }[]

  const socials = [
    c.twitter  && { icon: Twitter,       label: 'Twitter / X', href: c.twitter },
    c.telegram && { icon: TelegramIcon,  label: 'Telegram',    href: c.telegram },
    c.discord  && { icon: MessageCircle, label: 'Discord',     href: c.discord },
  ].filter(Boolean) as { icon: any; label: string; href: string }[]

  return (
    <div className="flex min-h-screen flex-col bg-app-bg text-app-text">
      <PublicHeader active="contact" />
      <main className="mx-auto w-full max-w-5xl flex-1 px-4 py-12 sm:py-16">
        <h1 className="mb-3 text-3xl font-bold sm:text-4xl">Contact us</h1>
        <p className="mb-10 max-w-2xl text-app-muted">
          Questions, feedback, or partnership enquiries, we'd love to hear from you.
        </p>

        <div className="grid gap-8 lg:grid-cols-2">
          {/* Details */}
          <div className="space-y-6">
            {details.length > 0 && (
              <div className="space-y-4">
                {details.map(({ icon: Icon, label, value, href }) => (
                  <div key={label} className="flex items-start gap-3">
                    <span className="mt-0.5 flex h-9 w-9 shrink-0 items-center justify-center rounded-lg bg-app-accent/10">
                      <Icon className="h-4 w-4 text-app-accent-text" />
                    </span>
                    <div>
                      <p className="text-xs text-app-muted">{label}</p>
                      {href
                        ? <a href={href} className="text-sm font-medium text-app-text hover:text-app-accent-text">{value}</a>
                        : <p className="whitespace-pre-wrap text-sm font-medium text-app-text">{value}</p>}
                    </div>
                  </div>
                ))}
              </div>
            )}

            {socials.length > 0 && (
              <div>
                <p className="mb-3 text-xs uppercase tracking-wide text-app-muted">Follow us</p>
                <div className="flex flex-wrap gap-3">
                  {socials.map(({ icon: Icon, label, href }) => (
                    <a key={label} href={href} target="_blank" rel="noopener noreferrer"
                      className="inline-flex items-center gap-2 rounded-lg border border-app-border bg-app-surface px-3 py-2 text-sm text-app-text hover:border-app-accent hover:text-app-accent-text">
                      <Icon className="h-4 w-4" /> {label}
                    </a>
                  ))}
                </div>
              </div>
            )}

            {details.length === 0 && socials.length === 0 && (
              <p className="text-app-muted">Contact details are being updated. You can still send us a message.</p>
            )}
          </div>

          {/* Message form */}
          <ContactForm />
        </div>
      </main>
      <PublicFooter />
    </div>
  )
}
