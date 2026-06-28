import { Router } from 'express'
import { getCachedRates, getRateByPair } from '../services/rateOracle'

const router = Router()

// GET /rates — all FX rates
router.get('/', (_req, res) => {
  res.json(getCachedRates())
})

// GET /rates/:pair — e.g. /rates/NGN%2FUSDC
router.get('/:pair', (req, res) => {
  const pair = decodeURIComponent(req.params.pair)
  const rate = getRateByPair(pair)
  if (!rate) return res.status(404).json({ error: `Rate not found for ${pair}` })
  res.json(rate)
})

export default router
