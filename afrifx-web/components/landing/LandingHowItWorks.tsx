'use client'
import { Reveal } from './Reveal'
import { Wallet, ArrowLeftRight, Send } from 'lucide-react'

const STEPS = [
  {
    n: '01',
    icon: Wallet,
    title: 'Connect or sign in',
    body: 'Use MetaMask, or sign in with Google or email to get a secure embedded wallet, no seed phrase needed.',
  },
  {
    n: '02',
    icon: ArrowLeftRight,
    title: 'Convert at live rates',
    body: 'Swap between USDC and African currencies with fees shown upfront, settled on Arc in seconds.',
  },
  {
    n: '03',
    icon: Send,
    title: 'Send across borders',
    body: 'Move value to any wallet, pay an invoice, or trade peer-to-peer, every step confirmed on-chain.',
  },
]

export function LandingHowItWorks() {
  return (
    <section className="border-y border-app-border bg-app-surface/40">
      <div className="mx-auto max-w-6xl px-4 py-20 sm:px-6">
        <Reveal>
          <div className="mx-auto max-w-2xl text-center">
            <span className="text-xs font-semibold uppercase tracking-[0.2em] text-app-accent-text">How it works</span>
            <h2 className="mt-3 text-3xl font-extrabold tracking-tight sm:text-4xl">
              Three steps to your first <span className="afx-gradient-text">on-chain payment</span>
            </h2>
          </div>
        </Reveal>

        <div className="relative mt-14 grid gap-8 sm:grid-cols-3">
          {/* connecting line on desktop */}
          <div className="pointer-events-none absolute left-0 right-0 top-7 hidden h-px bg-gradient-to-r from-transparent via-app-border to-transparent sm:block" />
          {STEPS.map((s, i) => {
            const Icon = s.icon
            return (
              <Reveal key={s.n} delay={i * 120}>
                <div className="relative text-center">
                  <div className="mx-auto flex h-14 w-14 items-center justify-center rounded-2xl border border-app-border bg-app-bg text-app-accent-text">
                    <Icon className="h-6 w-6" />
                  </div>
                  <div className="mt-4 text-xs font-semibold tracking-[0.2em] text-app-muted">{s.n}</div>
                  <h3 className="mt-1 text-lg font-semibold text-app-text">{s.title}</h3>
                  <p className="mx-auto mt-2 max-w-xs text-sm leading-relaxed text-app-muted">{s.body}</p>
                </div>
              </Reveal>
            )
          })}
        </div>
      </div>
    </section>
  )
}
