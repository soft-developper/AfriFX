// Multi-source rate oracle African currency focused
// Source 1: open.er-api.com   (free, no key, covers NGN/GHS/KES/ZAR/EGP)
// Source 2: exchangerate-api  (if EXCHANGE_RATE_API_KEY is set)
// Source 3: Last persisted DB rates (survives API outages for days)
// Source 4: Hardcoded absolute last resort

import type { FXRate } from '../types'
import { LOCAL_CURRENCIES } from '../types'

const TIMEOUT_MS = 8_000

// Hardcoded last-resort (only used if DB is also empty).
// Approximate units-per-USD; the live oracle overrides these.
const HARDCODED: Record<string, number> = {
  NGN: 1620,  GHS: 14.8,  KES: 130.5, ZAR: 18.6,  EGP: 49.2,
  UGX: 3750,  TZS: 2600,  RWF: 1350,  XOF: 605,   XAF: 605,
  ZMW: 27,    ETB: 122,   MZN: 64,    EUR: 0.92,
}

let cachedRates: FXRate[] = []
let failCount             = 0
let lastSuccessSource     = 'none'

// DB reference injected after init to avoid circular deps
let _db: any = null
export function injectDb(db: any) { _db = db }

export function getCachedRates(): FXRate[]  { return cachedRates }
export function getLastSource():   string   { return lastSuccessSource }

export function getRateByPair(pair: string): FXRate | undefined {
  return cachedRates.find(r => r.pair === pair)
}

export async function fetchLatestRates(): Promise<void> {
  const result = await tryLiveSources()

  if (result) {
    cachedRates       = result.rates
    lastSuccessSource = result.source
    failCount         = 0
    console.log(`[RateOracle] ✅ Rates updated from ${result.source}`)
    // Persist to DB for offline fallback
    await persistToDb(result.rates)
    return
  }

  // All live sources failed try DB
  failCount++
  if (failCount <= 3) {
    console.warn(`[RateOracle] Live sources failed (${failCount}), trying DB cache`)
  }

  const dbRates = await loadFromDb()
  if (dbRates.length) {
    cachedRates       = dbRates
    lastSuccessSource = 'db-cache'
    if (failCount <= 3) {
      console.warn(`[RateOracle] Serving ${dbRates.length} rates from DB cache`)
    }
    return
  }

  // DB also empty use hardcoded (only on first boot before any fetch)
  if (!cachedRates.length) {
    cachedRates       = buildRates(HARDCODED, 'hardcoded')
    lastSuccessSource = 'hardcoded'
    console.warn('[RateOracle] Using hardcoded fallback rates')
  }
}

async function tryLiveSources(): Promise<{ rates: FXRate[]; source: string } | null> {
  // Source 1 open.er-api.com (no key, covers all our currencies)
  try {
    const raw = await fetchOpenErApi()
    if (raw && hasOurCurrencies(raw)) {
      return { rates: buildRates(raw, 'open.er-api.com'), source: 'open.er-api.com' }
    }
  } catch {}

  // Source 2 exchangerate-api.com (if key configured)
  if (process.env.EXCHANGE_RATE_API_KEY) {
    try {
      const raw = await fetchExchangeRateApi(process.env.EXCHANGE_RATE_API_KEY)
      if (raw && hasOurCurrencies(raw)) {
        return { rates: buildRates(raw, 'exchangerate-api.com'), source: 'exchangerate-api.com' }
      }
    } catch {}
  }

  return null
}

// Validate that fetched rates actually contain our African currencies
function hasOurCurrencies(raw: Record<string, number>): boolean {
  return ['NGN', 'GHS', 'KES'].every(c => raw[c] && raw[c] > 0)
}

async function fetchOpenErApi(): Promise<Record<string, number> | null> {
  const res = await fetchWithTimeout('https://open.er-api.com/v6/latest/USD')
  if (!res.ok) return null
  const json = await res.json()
  return (json.result === 'success' || json.rates) ? json.rates : null
}

async function fetchExchangeRateApi(key: string): Promise<Record<string, number> | null> {
  const res = await fetchWithTimeout(
    `https://v6.exchangerate-api.com/v6/${key}/latest/USD`
  )
  if (!res.ok) return null
  const json = await res.json()
  return json.result === 'success' ? json.conversion_rates : null
}

async function fetchWithTimeout(url: string): Promise<Response> {
  const controller = new AbortController()
  const timer      = setTimeout(() => controller.abort(), TIMEOUT_MS)
  try {
    return await fetch(url, { signal: controller.signal })
  } finally {
    clearTimeout(timer)
  }
}

function buildRates(raw: Record<string, number>, source: string): FXRate[] {
  const prev = Object.fromEntries(cachedRates.map(r => [r.pair, r.rate]))
  const now  = Date.now()

  // raw contains "local units per USD" — use directly, falling back to the
  // hardcoded last-resort value when a feed omits a currency.
  // Driven by LOCAL_CURRENCIES so every supported currency gets a pair; adding
  // one to that list is all it takes for its rate to appear here.
  const rates: FXRate[] = LOCAL_CURRENCIES.map(cur => {
    const rate = raw[cur] ?? HARDCODED[cur]
    const pair = `${cur}/USDC`
    return { pair, rate, change24h: pct(prev[pair], rate), source, fetchedAt: now }
  })

  // EURC is priced off the EUR rate and isn't in LOCAL_CURRENCIES.
  const eur = raw.EUR ?? HARDCODED.EUR
  rates.push({
    pair: 'EURC/USDC', rate: eur, change24h: pct(prev['EURC/USDC'], eur),
    source, fetchedAt: now,
  })

  return rates
}

async function persistToDb(rates: FXRate[]): Promise<void> {
  if (!_db) return
  try {
    const { sql } = await import('drizzle-orm')
    for (const r of rates) {
      // Try upsert update if pair exists, insert if not
      try {
        await _db.run(
          sql`INSERT INTO fx_rates (pair, rate, change_24h, source, fetched_at)
              VALUES (${r.pair}, ${r.rate}, ${r.change24h}, ${r.source}, ${r.fetchedAt})`
        )
      } catch {
        await _db.run(
          sql`UPDATE fx_rates
              SET rate = ${r.rate}, change_24h = ${r.change24h},
                  source = ${r.source}, fetched_at = ${r.fetchedAt}
              WHERE pair = ${r.pair}`
        )
      }
    }
  } catch (err: any) {
    console.error('[RateOracle] DB persist failed:', err.message)
  }
}

async function loadFromDb(): Promise<FXRate[]> {
  if (!_db) return []
  try {
    const { sql } = await import('drizzle-orm')
    const rows    = await _db.run(
      sql`SELECT pair, rate, change_24h, source, fetched_at
          FROM fx_rates ORDER BY fetched_at DESC`
    )
    const all = Array.isArray((rows as any).rows) ? (rows as any).rows : []
    const seen = new Set<string>()
    const result: FXRate[] = []
    for (const r of all) {
      const pair = r.pair ?? r[0]
      if (!seen.has(pair)) {
        seen.add(pair)
        result.push({
          pair,
          rate:      Number(r.rate      ?? r[1]),
          change24h: Number(r.change_24h ?? r[2] ?? 0),
          source:    String(r.source    ?? r[3] ?? 'db-cache'),
          fetchedAt: Number(r.fetched_at ?? r[4] ?? 0),
        })
      }
    }
    return result
  } catch {
    return []
  }
}

function pct(prev: number | undefined, curr: number): number {
  if (!prev || !curr) return 0
  return parseFloat((((curr - prev) / prev) * 100).toFixed(2))
}
