// Arc Transaction Memo event listener
// Docs: https://docs.arc.io/arc/concepts/transaction-memos
// Memo contract: 0x5294E9927c3306DcBaDb03fe70b92e01cCede505

import { arcClient } from './arc'
import { db }        from '../db/client'
import { sql }       from 'drizzle-orm'
import { parseAbiItem } from 'viem'

const MEMO_ADDRESS = '0x5294E9927c3306DcBaDb03fe70b92e01cCede505' as const

// Official Memo event from docs.arc.io
const MEMO_EVENT = parseAbiItem(
  'event Memo(address indexed sender, address indexed target, bytes32 callDataHash, bytes32 indexed memoId, bytes memo, uint256 memoIndex)'
)

interface AfriFXMemoPayload {
  app:       string
  type:      string
  ref?:      string
  pair?:     string
  corridorId?: string
  offerId?:  string
  step?:     number
}

function decodeMemo(memoHex: string): AfriFXMemoPayload | null {
  try {
    const json = Buffer.from(memoHex.replace('0x', ''), 'hex').toString('utf8')
    const parsed = JSON.parse(json)
    return parsed.app === 'afrifx' ? parsed : null
  } catch { return null }
}

export function startEventListener() {
  console.log('[EventListener] Watching Arc Memo events for AfriFX txs')
  console.log(`[EventListener] Memo contract: ${MEMO_ADDRESS}`)

  arcClient.watchEvent({
    address: MEMO_ADDRESS,
    event:   MEMO_EVENT,
    onLogs: async (logs) => {
      for (const log of logs) {
        const { sender, memoId, memo: memoBytes } = log.args as {
          sender:  string
          memoId:  string
          memo:    string
        }

        const payload = decodeMemo(memoBytes)
        if (!payload) continue // not an AfriFX memo

        const txHash = log.transactionHash ?? ''
        const now    = Math.floor(Date.now() / 1000)

        console.log(`[EventListener] AfriFX Memo · type: ${payload.type} · ref: ${payload.ref ?? 'n/a'} · tx: ${txHash.slice(0,14)}…`)

        // Handle each memo type
        switch (payload.type) {
          case 'convert':
          case 'corridor-step1':
          case 'corridor-step2':
            // Mark transaction as settled by memoId
            await db.run(
              sql`UPDATE transactions
                  SET status = 'settled', arc_tx_hash = ${txHash}, settled_at = ${now}
                  WHERE memo_id = ${memoId}`
            ).catch(console.error)
            break

          case 'p2p-taker-confirm':
          case 'p2p-maker-confirm':
            // Update offer confirmed status by memoId
            if (payload.offerId) {
              await db.run(
                sql`UPDATE p2p_offers SET updated_at = ${now} WHERE id = ${payload.offerId}`
              ).catch(console.error)
            }
            break

          default:
            break
        }
      }
    },
    onError: (err) => {
      console.error('[EventListener] Watch error:', err.message)
    },
  })
}
