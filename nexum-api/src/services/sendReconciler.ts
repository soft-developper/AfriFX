// ============================================================
// Send reconciler — settles pending non-Arc sends by their REAL on-chain
// receipt, never by an optimistic guess.
//
// WHY: a Circle transfer can surface a txHash before it is confirmed on-chain.
// The send page must NOT mark such a send "settled" just because a hash exists
// (it could still revert). Instead, non-Arc sends that aren't yet confirmed are
// left "pending", and this backstop — mirroring startTransferReconciler — polls
// each chain's own RPC for the transaction receipt and settles only on ground
// truth: receipt.status === 'success' -> settled, 'reverted' -> failed, no
// receipt yet -> leave pending and retry next tick.
//
// Arc sends are unaffected: the send page already confirms those via the wagmi
// receipt at send time. This job only touches rows with a non-Arc from_chain.
//
// RPC URLs mirror the web's rpcUrlFor(), env-overridable so prod can point at
// dedicated endpoints. If a chain has no RPC configured we skip it (leave
// pending) rather than guess.
// ============================================================

import cron from 'node-cron'
import { createPublicClient, http } from 'viem'
import { db } from '../db/client'
import { sql } from 'drizzle-orm'

// Internal chain key -> testnet EVM chain id (mirrors web evmChainId testnet map).
const CHAIN_ID_TESTNET: Record<string, number> = {
  base: 84532, ethereum: 11155111, arbitrum: 421614, polygon: 80002,
  optimism: 11155420, avalanche: 43113, unichain: 1301, monad: 10143,
}
const CHAIN_ID_MAINNET: Record<string, number> = {
  base: 8453, ethereum: 1, arbitrum: 42161, polygon: 137,
}

function chainIdFor(key: string): number | undefined {
  const isMainnet = (process.env.CCTP_ENV ?? 'testnet') === 'mainnet'
  return (isMainnet ? CHAIN_ID_MAINNET : CHAIN_ID_TESTNET)[key]
}

// chain key -> RPC URL. Env overrides first, then a sensible public default
// (same defaults the web uses). Arc is intentionally absent: Arc sends are
// confirmed client-side, so the reconciler never needs an Arc RPC.
function rpcUrlForKey(key: string): string | undefined {
  const isMainnet = (process.env.CCTP_ENV ?? 'testnet') === 'mainnet'
  const testnet: Record<string, string> = {
    base:      process.env.BASE_RPC_URL     ?? 'https://sepolia.base.org',
    ethereum:  process.env.ETH_RPC_URL      ?? 'https://ethereum-sepolia-rpc.publicnode.com',
    arbitrum:  process.env.ARB_RPC_URL      ?? 'https://sepolia-rollup.arbitrum.io/rpc',
    polygon:   process.env.POLYGON_RPC_URL  ?? 'https://polygon-amoy-bor-rpc.publicnode.com',
    optimism:  process.env.OP_RPC_URL       ?? 'https://sepolia.optimism.io',
    avalanche: process.env.AVAX_RPC_URL     ?? 'https://api.avax-test.network/ext/bc/C/rpc',
    unichain:  process.env.UNICHAIN_RPC_URL ?? 'https://sepolia.unichain.org',
    monad:     process.env.MONAD_RPC_URL    ?? 'https://testnet-rpc.monad.xyz',
  }
  const mainnet: Record<string, string> = {
    base:     process.env.BASE_RPC_URL    ?? 'https://mainnet.base.org',
    ethereum: process.env.ETH_RPC_URL     ?? '',
    arbitrum: process.env.ARB_RPC_URL     ?? 'https://arb1.arbitrum.io/rpc',
    polygon:  process.env.POLYGON_RPC_URL ?? 'https://polygon-rpc.com',
  }
  const url = (isMainnet ? mainnet : testnet)[key]
  return url && url.length ? url : undefined
}

const rowVal = (row: any, key: string, i: number) => Array.isArray(row) ? row[i] : row[key]

function parseRows(res: any): any[] {
  return res?.rows ?? res ?? []
}

export function startSendReconciler() {
  console.log('[SendReconciler] \u2705 Started — settling pending non-Arc sends by on-chain receipt every 2 minutes')
  cron.schedule('*/2 * * * *', reconcile)
  setTimeout(reconcile, 20_000) // shortly after boot too
}

async function reconcile() {
  try {
    // Only rows still 'pending', with a real hash and a NON-Arc from_chain,
    // that have had a moment to confirm. Arc rows (from_chain null/'arc') are
    // confirmed client-side and never touched here.
    const cutoff = Math.floor(Date.now() / 1000) - 60
    const rows = parseRows(await db.run(sql`
      SELECT id, arc_tx_hash, from_chain
        FROM transactions
       WHERE status = 'pending'
         AND arc_tx_hash IS NOT NULL
         AND from_chain IS NOT NULL
         AND from_chain <> 'arc'
         AND created_at < ${cutoff}
       LIMIT 50`))
    if (!rows.length) return

    // Group by chain so we make one client per chain per tick.
    const clients = new Map<string, ReturnType<typeof createPublicClient>>()

    for (const r of rows) {
      const id    = rowVal(r, 'id', 0)
      const hash  = rowVal(r, 'arc_tx_hash', 1)
      const chain = rowVal(r, 'from_chain', 2)
      if (!hash || !chain) continue

      const rpc = rpcUrlForKey(chain)
      const cid = chainIdFor(chain)
      if (!rpc || !cid) continue // unknown/unconfigured chain — leave pending

      let client = clients.get(chain)
      if (!client) {
        client = createPublicClient({ transport: http(rpc) })
        clients.set(chain, client)
      }

      try {
        // Ground truth: the chain's own receipt.
        const receipt = await client.getTransactionReceipt({ hash: hash as `0x${string}` })
        const now = Math.floor(Date.now() / 1000)
        if (receipt.status === 'success') {
          await db.run(sql`UPDATE transactions SET status='settled', settled_at=${now} WHERE id=${id} AND status='pending'`)
          console.log(`[SendReconciler] settled ${id} (${chain}) via on-chain receipt`)
        } else if (receipt.status === 'reverted') {
          await db.run(sql`UPDATE transactions SET status='failed' WHERE id=${id} AND status='pending'`)
          console.log(`[SendReconciler] failed ${id} (${chain}) — reverted on-chain`)
        }
      } catch {
        // No receipt yet (still mining) or transient RPC error — leave pending,
        // retry next tick. Never settle without a receipt.
      }
    }
  } catch (err: any) {
    console.error('[SendReconciler] tick error:', err?.message ?? err)
  }
}
