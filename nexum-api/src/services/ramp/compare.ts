// ============================================================
// Provider comparison, "which ramp should I use?"
//
// Fans out a quote request to every provider that CAN serve the requested pair,
// and returns them all so the user chooses. We deliberately do NOT rank: the
// best rate is often not the fastest, and picking a winner on the user's behalf
// means implicitly steering them toward whichever provider we favour. Rate, fee,
// net amount and speed are all surfaced; the judgement is theirs.
//
// TWO DESIGN POINTS THAT MATTER
//
// 1. TIMEOUTS ARE PER PROVIDER. Quoting is a live network call. Without an
//    individual timeout, one slow or dead provider stalls the entire comparison
//    and the user sees a spinner instead of the three providers that answered
//    fine. Each is raced against a deadline and failures are reported inline.
//
// 2. FAILURES ARE VISIBLE, NOT HIDDEN. A provider that errors is returned with
//    ok:false and a reason, rather than being dropped. Silently omitting it
//    would look identical to it not existing, which is misleading when the user
//    is comparing options.
// ============================================================

import type { ProviderQuote, ProviderCapabilities, PayoutMethod } from './types'
import { getProvider, listProviders } from './registry'

const QUOTE_TIMEOUT_MS = Number(process.env.RAMP_QUOTE_TIMEOUT_MS ?? 8000)

function withTimeout<T>(p: Promise<T>, ms: number, label: string): Promise<T> {
  return Promise.race([
    p,
    new Promise<T>((_, reject) =>
      setTimeout(() => reject(new Error(`${label} did not respond in time`)), ms)),
  ])
}

/*
  Capability lookup.

  A provider may optionally expose `capabilities()`. When it doesn't, we assume
  it can serve the request rather than excluding it, because a missing
  declaration is not evidence of incapacity. The quote call itself will fail
  cleanly if it genuinely can't.
*/
export async function providerCapabilities(): Promise<ProviderCapabilities[]> {
  const out: ProviderCapabilities[] = []
  for (const key of listProviders()) {
    try {
      const p: any = getProvider(key)
      if (typeof p.capabilities === 'function') {
        out.push(await p.capabilities())
      } else {
        out.push({
          key,
          displayName: key.charAt(0).toUpperCase() + key.slice(1),
          countries: [], currencies: [], methods: ['bank', 'mobile_money'],
          configured: true,
          note: 'Capabilities not declared; availability confirmed at quote time.',
        })
      }
    } catch {
      // A provider that can't even be constructed shouldn't break the list.
    }
  }
  return out
}

function canServe(
  cap: ProviderCapabilities | undefined,
  destCurrency: string, country: string, method?: PayoutMethod,
): boolean {
  if (!cap) return true            // undeclared, let the quote decide
  if (!cap.configured) return false
  if (cap.currencies.length && !cap.currencies.includes(destCurrency)) return false
  if (cap.countries.length  && !cap.countries.includes(country))       return false
  if (method && cap.methods.length && !cap.methods.includes(method))   return false
  return true
}

/*
  Ask every capable provider for a quote, in parallel.

  Returns ALL results, including failures, in registry order. The caller (and
  ultimately the user) decides which to use.
*/
export async function compareProviders(params: {
  usdcAmount:   number
  destCurrency: string
  country:      string
  method?:      PayoutMethod
}): Promise<ProviderQuote[]> {
  const caps = await providerCapabilities()
  const capByKey = new Map(caps.map(c => [c.key, c]))

  const candidates = listProviders().filter(key =>
    canServe(capByKey.get(key), params.destCurrency, params.country, params.method))

  const results = await Promise.all(candidates.map(async (key): Promise<ProviderQuote> => {
    const cap = capByKey.get(key)
    const displayName = cap?.displayName ?? key
    try {
      const provider = getProvider(key)
      const quote = await withTimeout(
        provider.getPayoutQuote({
          usdcAmount:   params.usdcAmount,
          destCurrency: params.destCurrency,
          country:      params.country,
        }),
        QUOTE_TIMEOUT_MS,
        displayName,
      )

      // Fill in the comparison fields a provider didn't supply, so the UI has
      // something consistent to render. netDest defaults to destAmount when no
      // fee was disclosed, and is clearly labelled as such upstream.
      const feeDest = quote.feeDest ?? 0
      const netDest = quote.netDest ?? (quote.destAmount - feeDest)

      return {
        provider: key, displayName, ok: true,
        quote: { ...quote, feeDest, netDest },
      }
    } catch (err: any) {
      return {
        provider: key, displayName, ok: false,
        error: err?.message ?? 'Quote failed',
      }
    }
  }))

  return results
}
