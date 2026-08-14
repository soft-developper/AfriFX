export function formatUSDC(raw: bigint, decimals = 6): string {
  const n = Number(raw) / 10 ** decimals
  return n.toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 })
}

export function nowMs(): number { return Date.now() }
export function nowSec(): number { return Math.floor(Date.now() / 1000) }

export function shortenHash(hash: string, chars = 6): string {
  return `${hash.slice(0, chars + 2)}…${hash.slice(-chars)}`
}
