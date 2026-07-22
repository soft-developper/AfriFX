// ============================================================
// Bridge routes.
//
//   POST /bridge                  create a bridge record (BEFORE signing)
//   GET  /bridge?wallet=0x…       a wallet's bridge history
//   GET  /bridge/:id              one bridge
//   POST /bridge/:id/burned       record a confirmed burn  <- THE critical one
//   POST /bridge/:id/attested     record Circle's attestation
//   POST /bridge/:id/completed    record the mint
//   POST /bridge/:id/failed       record a failure (auto-classifies stranded)
//   GET  /bridge/meta/unresolved  ops view of anything stuck
//
// The user's wallet signs the transactions client-side (non-custodial), so
// these endpoints RECORD progress rather than perform it. That's deliberate:
// the platform never holds keys, and a compromised API can't move funds.
// ============================================================

import { Router } from 'express'
import {
  createBridge, getBridge, listBridgesByWallet, listUnresolved,
  markBurning, markBurned, markAttested, markCompleted, markFailed,
  nextAction, isInFlight,
} from '../services/bridge/repository'

const router = Router()

// ── Create (called BEFORE the user signs anything) ─────────
router.post('/', async (req, res) => {
  const {
    walletAddress, fromChain, toChain, fromDomain, toDomain, amount, recipient,
  } = req.body

  if (!walletAddress) return res.status(400).json({ error: 'walletAddress required' })
  if (!fromChain || !toChain) return res.status(400).json({ error: 'fromChain and toChain required' })
  if (fromChain === toChain)  return res.status(400).json({ error: 'Source and destination must differ' })
  if (fromDomain == null || toDomain == null) {
    return res.status(400).json({ error: 'fromDomain and toDomain required' })
  }
  if (!amount || Number(amount) <= 0) return res.status(400).json({ error: 'A positive amount is required' })
  if (!recipient) return res.status(400).json({ error: 'recipient required' })

  try {
    const id = await createBridge({
      walletAddress, fromChain, toChain,
      fromDomain: Number(fromDomain), toDomain: Number(toDomain),
      amount: Number(amount), recipient,
    })
    res.status(201).json({ id, status: 'created' })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// ── Read ───────────────────────────────────────────────────
router.get('/', async (req, res) => {
  const wallet = req.query.wallet as string | undefined
  if (!wallet) return res.status(400).json({ error: 'wallet required' })
  try {
    const list = await listBridgesByWallet(wallet)
    res.json(list.map(b => ({ ...b, nextAction: nextAction(b), inFlight: isInFlight(b) })))
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

router.get('/meta/unresolved', async (_req, res) => {
  try {
    const list = await listUnresolved()
    res.json(list.map(b => ({ ...b, nextAction: nextAction(b), inFlight: isInFlight(b) })))
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

router.get('/:id', async (req, res) => {
  try {
    const rec = await getBridge(req.params.id)
    if (!rec) return res.status(404).json({ error: 'Bridge not found' })
    res.json({ ...rec, nextAction: nextAction(rec), inFlight: isInFlight(rec) })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// ── Progress reporting ─────────────────────────────────────
router.post('/:id/burning', async (req, res) => {
  try { await markBurning(req.params.id); res.json({ ok: true }) }
  catch (err: any) { res.status(500).json({ error: err.message }) }
})

/*
  THE CRITICAL ENDPOINT. Once this is stored the funds are burned and the mint
  is owed. messageBytes + messageHash are what make the mint completable later
  by anyone, so we REQUIRE them rather than accepting a bare tx hash — a burn
  recorded without them would be much harder to recover.
*/
router.post('/:id/burned', async (req, res) => {
  const { burnTx, messageBytes, messageHash } = req.body
  if (!burnTx)       return res.status(400).json({ error: 'burnTx required' })
  if (!messageBytes) return res.status(400).json({ error: 'messageBytes required (needed to complete the mint later)' })
  if (!messageHash)  return res.status(400).json({ error: 'messageHash required (needed to fetch the attestation)' })
  try {
    await markBurned(req.params.id, { burnTx, messageBytes, messageHash })
    res.json({ ok: true, status: 'attesting' })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

router.post('/:id/attested', async (req, res) => {
  const { attestation } = req.body
  if (!attestation) return res.status(400).json({ error: 'attestation required' })
  try { await markAttested(req.params.id, attestation); res.json({ ok: true, status: 'minting' }) }
  catch (err: any) { res.status(500).json({ error: err.message }) }
})

router.post('/:id/completed', async (req, res) => {
  const { mintTx } = req.body
  if (!mintTx) return res.status(400).json({ error: 'mintTx required' })
  try { await markCompleted(req.params.id, mintTx); res.json({ ok: true, status: 'completed' }) }
  catch (err: any) { res.status(500).json({ error: err.message }) }
})

router.post('/:id/failed', async (req, res) => {
  const { error: reason } = req.body
  try {
    // The repository decides failed-vs-stranded based on whether a burn landed,
    // so a client can't accidentally mark burned funds as harmlessly failed.
    const outcome = await markFailed(req.params.id, String(reason ?? 'unknown'))
    res.json({ ok: true, status: outcome })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

export default router
