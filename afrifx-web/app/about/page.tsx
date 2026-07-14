import Link from 'next/link'
import { PublicHeader, PublicFooter } from '@/components/public/PublicChrome'

const API = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'

interface Section { heading: string; body: string }

async function getSections(): Promise<Section[]> {
  try {
    const res = await fetch(`${API}/content/about`, { next: { revalidate: 60 } })
    if (!res.ok) return []
    const data = await res.json()
    return Array.isArray(data.sections) ? data.sections : []
  } catch { return [] }
}

export const metadata = {
  title: 'About, AfriFX',
  description: 'Learn about AfriFX, decentralized stablecoin FX and cross-border payments on Arc.',
}

export default async function AboutPage() {
  const sections = await getSections()

  return (
    <div className="flex min-h-screen flex-col bg-app-bg text-app-text">
      <PublicHeader active="about" />
      <main className="mx-auto w-full max-w-3xl flex-1 px-4 py-12 sm:py-16">
        <h1 className="mb-8 text-3xl font-bold sm:text-4xl">About</h1>
        {sections.length === 0 ? (
          <p className="text-app-muted">Content is being updated. Please check back soon.</p>
        ) : (
          <div className="space-y-10">
            {sections.map((s, i) => (
              <section key={i}>
                {s.heading && <h2 className="mb-3 text-xl font-semibold sm:text-2xl">{s.heading}</h2>}
                {s.body && (
                  <p className="whitespace-pre-wrap leading-relaxed text-app-muted">{s.body}</p>
                )}
              </section>
            ))}
          </div>
        )}
        <div className="mt-12 border-t border-app-border pt-6">
          <Link href="/contact" className="text-sm font-medium text-app-accent-text hover:underline">
            Have a question? Contact us →
          </Link>
        </div>
      </main>
      <PublicFooter />
    </div>
  )
}
