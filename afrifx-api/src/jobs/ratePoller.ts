import cron from 'node-cron'
import { fetchLatestRates, injectDb } from '../services/rateOracle'
import { db } from '../db/client'

export function startRatePoller() {
  // Give oracle access to DB for persistence + fallback
  injectDb(db)

  console.log('[RatePoller] Starting — fetching every 30 minutes')

  // Run immediately on boot
  fetchLatestRates()

  // Then every 30 minutes
  cron.schedule('*/30 * * * *', fetchLatestRates)
}
