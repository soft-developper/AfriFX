// Checks auto-conversion rules every hour
// Marks triggered rules user executes manually (no stored keys)
import cron from 'node-cron'
import { db } from '../db/client'
import { sql } from 'drizzle-orm'
import { createPublicClient, http, formatUnits } from 'viem'

const ARC_RPC   = process.env.ARC_RPC_URL ?? 'https://rpc.testnet.arc.network'
const USDC_ADDR = '0x3600000000000000000000000000000000000000' as const
const ERC20_ABI = [{
  name: 'balanceOf', type: 'function', stateMutability: 'view',
  inputs: [{ name: 'account', type: 'address' }],
  outputs: [{ name: '', type: 'uint256' }],
}] as const

const arcClient = createPublicClient({
  transport: http(ARC_RPC),
  chain: {
    id: 5042002, name: 'Arc Testnet',
    nativeCurrency: { name: 'ARC', symbol: 'ARC', decimals: 18 },
    rpcUrls: { default: { http: [ARC_RPC] } },
  } as any,
})

function parseRows(r: any): any[] {
  if (!r) return []
  if (Array.isArray((r as any).rows)) return (r as any).rows
  if (Array.isArray(r)) return r
  return []
}

export function startTreasuryChecker() {
  console.log('[TreasuryChecker] ✅ Started, checks every hour')

  // Run every hour
  cron.schedule('0 * * * *', checkRules)

  // Also run 30s after boot
  setTimeout(checkRules, 30_000)
}

async function checkRules() {
  try {
    const rows = await db.run(
      sql`SELECT * FROM treasury_rules WHERE status = 'active'`
    )
    const rules = parseRows(rows)
    if (!rules.length) return

    const now = Math.floor(Date.now() / 1000)

    for (const r of rules) {
      const id        = r.id            ?? r[0]
      const wallet    = r.wallet_address ?? r[1]
      const threshold = Number(r.trigger_threshold ?? r[3])

      try {
        // Check on-chain USDC balance
        const raw      = await arcClient.readContract({
          address:      USDC_ADDR,
          abi:          ERC20_ABI,
          functionName: 'balanceOf',
          args:         [wallet as `0x${string}`],
        }).catch(() => 0n)

        const balance = parseFloat(formatUnits(BigInt(raw), 6))

        if (balance >= threshold) {
          await db.run(
            sql`UPDATE treasury_rules SET
                  status         = 'triggered',
                  last_triggered = ${now}
                WHERE id = ${id}`
          )
          console.log(`[TreasuryChecker] ⚡ Rule triggered for ${wallet.slice(0,10)}…, balance ${balance} >= ${threshold}`)
        }
      } catch {}
    }
  } catch (err: any) {
    console.error('[TreasuryChecker] Error:', err.message)
  }
}
