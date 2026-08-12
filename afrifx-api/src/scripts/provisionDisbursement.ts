// ============================================================
// provisionDisbursement.ts - run ONCE to create the platform payroll wallet.
//
// Usage (from afrifx-api):
//   CIRCLE_API_KEY=... CIRCLE_ENTITY_SECRET=... npx tsx src/scripts/provisionDisbursement.ts
//
// It prints the new wallet's id and address. Save them:
//   * PAYROLL_DISBURSEMENT_WALLET_ID   -> env (used by the payout engine, 7c)
//   * the address is what employers FUND (7b)
//
// This is deliberately a manual script, not an auto-running route: it creates a
// custody wallet and should be an explicit, one-time, human-run action. It does
// not print the entity secret.
// ============================================================

import * as dotenv from 'dotenv'
dotenv.config()

import { provisionDisbursementWallet } from '../services/platformDisbursement'

async function main() {
  if (!process.env.CIRCLE_ENTITY_SECRET) {
    console.error(
      'CIRCLE_ENTITY_SECRET is not set. Generate one with the Circle SDK\n' +
      "(generateEntitySecret()), register it in the Circle console, then set it\n" +
      'in the environment before running this script.')
    process.exit(1)
  }

  console.log('Provisioning the payroll disbursement wallet...')
  const wallet = await provisionDisbursementWallet()

  console.log('\nDone. Save these:')
  console.log(`  PAYROLL_DISBURSEMENT_WALLET_ID = ${wallet.id}`)
  console.log(`  address (fund this)            = ${wallet.address}`)
  console.log(`  blockchain                     = ${wallet.blockchain}`)
  console.log(
    '\nNext: set PAYROLL_DISBURSEMENT_WALLET_ID in the API environment. ' +
    'Employers will fund the address above (Phase 7b), and the backend pays ' +
    'out from it (Phase 7c).')
}

main().catch(err => {
  console.error('Provisioning failed:', err?.message ?? err)
  process.exit(1)
})
