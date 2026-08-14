#!/usr/bin/env bash
# =============================================================================
# gateway-probe.sh - writes the Gateway probe into afrifx-api and runs it.
#
# WHY A .sh WRAPPER: so you never have to hunt for or move a .mjs file. Run this
# ONE script from the repo root; it drops gateway-probe.mjs into afrifx-api and
# runs it with node. Same probe as before, zero file-shuffling.
#
#   cd ~/AfriFX
#   bash gateway-probe.sh
#
# It reads afrifx-api/.env automatically (via the probe's dotenv import). If your
# env isn't in a .env file, the script will tell you and show the inline form.
#
# SAFE: moves at most 0.10 test USDC of the FLOAT wallet, to the float's own
# address on Base. Cleans up the .mjs afterward so nothing is committed.
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
API="$ROOT/afrifx-api"

[ -d "$API" ] || { echo "ERR: afrifx-api not found - run this from the AfriFX repo root"; exit 1; }
[ -d "$API/node_modules/@circle-fin/developer-controlled-wallets" ] || {
  echo "ERR: Circle SDK not installed in afrifx-api. Run 'cd afrifx-api && npm install' first."; exit 1; }

echo "==> Writing gateway-probe.mjs into afrifx-api"
cat > "$API/gateway-probe.mjs" << 'PROBE_SRC_EOF'
// ============================================================================
// gateway-probe.mjs — Isolated backend Gateway proof (run locally, not deployed)
//
// Proves (or disproves) the three things the payout integration depends on,
// each reported independently so a failure pinpoints exactly which step broke:
//
//   STEP 1  Read the EOA float wallet's unified Gateway balance (POST /balances)
//   STEP 2  Deposit a tiny amount of the Arc float into Gateway (approve+deposit)
//   STEP 3  Sign ONE burn intent with the EOA float wallet (backend signTypedData)
//           and submit to /transfer for a Base Sepolia mint — the linchpin.
//
// This mirrors the logic in afrifx-web/lib/gateway.ts + hooks/useGatewaySend.ts,
// but signs SERVER-SIDE with the developer-controlled wallet (no user token).
//
// RUN:
//   cd ~/AfriFX/afrifx-api
//   cp /path/to/gateway-probe.mjs .
//   node gateway-probe.mjs                # uses .env via dotenv if present
//   # or inline:
//   CIRCLE_API_KEY=... CIRCLE_ENTITY_SECRET=... \
//   PAYROLL_DISBURSEMENT_WALLET_ID=... node gateway-probe.mjs
//
// SAFE: moves at most PROBE_AMOUNT (default 0.10) USDC of the float, to the
// float's OWN address on Base. Delete this file after; it references secrets.
// ============================================================================
import 'dotenv/config'
import { initiateDeveloperControlledWalletsClient } from '@circle-fin/developer-controlled-wallets'

// ── Config ──────────────────────────────────────────────────────────────────
const API_KEY   = process.env.CIRCLE_API_KEY
const SECRET    = process.env.CIRCLE_ENTITY_SECRET
const WALLET_ID = process.env.PAYROLL_DISBURSEMENT_WALLET_ID
const GATEWAY_API = process.env.NEXT_PUBLIC_CCTP_ENV === 'mainnet'
  ? 'https://gateway-api.circle.com/v1'
  : 'https://gateway-api-testnet.circle.com/v1'
const PROBE_AMOUNT = Number(process.env.PROBE_AMOUNT ?? '0.10')

// Gateway contracts (from afrifx-web/lib/gateway.ts — deterministic addresses).
const GATEWAY_WALLET  = '0x0077777d7EBA4688BDeF3E311b846F25870A19B9'
const GATEWAY_MINTER  = '0x0022222ABE238Cc2C7Bb1f21003F0a260052475B'
// USDC (ERC-20 interface) address, same on Arc testnet as the payout path uses.
const USDC_ADDR       = process.env.CIRCLE_USDC_ERC20_ADDRESS ?? '0x3600000000000000000000000000000000000000'

// Domains (CCTP identifiers, from gateway.ts): Arc=26 source, Base=6 dest.
const SRC_DOMAIN = 26
const DST_DOMAIN = 6

if (!API_KEY || !SECRET || !WALLET_ID) {
  console.error('Missing env: CIRCLE_API_KEY / CIRCLE_ENTITY_SECRET / PAYROLL_DISBURSEMENT_WALLET_ID')
  process.exit(1)
}

const c = initiateDeveloperControlledWalletsClient({ apiKey: API_KEY, entitySecret: SECRET })

// ── Helpers ─────────────────────────────────────────────────────────────────
const units = (usdc) => BigInt(Math.round(usdc * 1e6)).toString()   // 6-decimals
const toBytes32 = (addr) => `0x${'0'.repeat(24)}${addr.toLowerCase().replace(/^0x/, '')}`
const ZERO32 = `0x${'0'.repeat(64)}`
function randomSalt() {
  const b = new Uint8Array(32); globalThis.crypto.getRandomValues(b)
  return `0x${Array.from(b).map(x => x.toString(16).padStart(2, '0')).join('')}`
}

async function getFloatAddress() {
  const w = await c.getWallet({ id: WALLET_ID })
  return w.data?.wallet?.address
}

// ── STEP 1: unified balance ─────────────────────────────────────────────────
async function step1_balance(address) {
  console.log('\n=== STEP 1: unified Gateway balance ===')
  try {
    const res = await fetch(`${GATEWAY_API}/balances`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', accept: 'application/json' },
      body: JSON.stringify({
        token: 'USDC',
        sources: [
          { domain: SRC_DOMAIN, depositor: address },
          { domain: DST_DOMAIN, depositor: address },
        ],
      }),
    })
    const text = await res.text()
    console.log('  status:', res.status)
    console.log('  body:', text.slice(0, 400))
    if (res.ok) {
      const data = JSON.parse(text)
      const total = (data.balances ?? []).reduce((s, b) => s + Number(b.balance ?? 0), 0)
      console.log('  → unified USDC balance:', total)
      return total
    }
  } catch (e) {
    console.log('  ERROR:', e?.message)
  }
  return null
}

// ── STEP 2: deposit float → Gateway (approve + deposit) ─────────────────────
async function step2_deposit() {
  console.log('\n=== STEP 2: deposit float into Gateway (approve + deposit) ===')
  const amount = units(PROBE_AMOUNT)
  try {
    // 2a. approve(GatewayWallet, amount) on the USDC contract
    console.log(`  2a. approve ${PROBE_AMOUNT} USDC to GatewayWallet...`)
    const approve = await c.createContractExecutionTransaction({
      walletId: WALLET_ID,
      contractAddress: USDC_ADDR,
      abiFunctionSignature: 'approve(address,uint256)',
      abiParameters: [GATEWAY_WALLET, amount],
      fee: { type: 'level', config: { feeLevel: 'MEDIUM' } },
    })
    console.log('     approve tx id:', approve.data?.id, 'state:', approve.data?.state)

    // Wait for approve to reach a mined-ish state before deposit.
    await waitTx(approve.data?.id)

    // 2b. deposit(token, amount) on the GatewayWallet contract
    console.log(`  2b. deposit ${PROBE_AMOUNT} USDC into GatewayWallet...`)
    const deposit = await c.createContractExecutionTransaction({
      walletId: WALLET_ID,
      contractAddress: GATEWAY_WALLET,
      abiFunctionSignature: 'deposit(address,uint256)',
      abiParameters: [USDC_ADDR, amount],
      fee: { type: 'level', config: { feeLevel: 'MEDIUM' } },
    })
    console.log('     deposit tx id:', deposit.data?.id, 'state:', deposit.data?.state)
    await waitTx(deposit.data?.id)
    console.log('  → deposit submitted. NOTE: Gateway credits the unified balance only')
    console.log('    AFTER source-chain finality (Arc ~0.5s, but the API may lag a few s).')
    return true
  } catch (e) {
    console.log('  ERROR:', e?.code ?? '', e?.message)
    if (e?.response?.data) console.log('  response.data:', JSON.stringify(e.response.data).slice(0, 300))
    return false
  }
}

async function waitTx(id, tries = 10) {
  if (!id) return
  for (let i = 0; i < tries; i++) {
    try {
      const t = await c.getTransaction({ id })
      const st = t.data?.transaction?.state
      if (['CONFIRMED', 'COMPLETE', 'SENT'].includes(st)) { console.log(`     ${id} → ${st}`); return }
      if (['FAILED', 'DENIED', 'CANCELLED'].includes(st)) { console.log(`     ${id} → ${st} (stopping)`); return }
    } catch {}
    await new Promise(r => setTimeout(r, 3000))
  }
  console.log(`     ${id} → still pending after wait (continuing)`)
}

// ── STEP 3: sign ONE burn intent (backend) + submit to /transfer ────────────
async function step3_burnIntent(address) {
  console.log('\n=== STEP 3: burn intent signed by EOA float wallet → /transfer ===')
  const value = units(PROBE_AMOUNT)

  // maxBlockHeight must clear the wallet's withdrawalDelay. We can't easily read
  // the Base head here without an RPC dep, so use a large absolute ceiling; if
  // Circle wants a specific minimum, its error states it and we log it.
  const maxBlockHeight = (BigInt(10) ** BigInt(15)).toString()

  const spec = {
    version: 1,
    sourceDomain: SRC_DOMAIN,
    destinationDomain: DST_DOMAIN,
    sourceContract: toBytes32(GATEWAY_WALLET),
    destinationContract: toBytes32(GATEWAY_MINTER),
    sourceToken: toBytes32(USDC_ADDR),
    destinationToken: toBytes32(USDC_ADDR),
    sourceDepositor: toBytes32(address),
    destinationRecipient: toBytes32(address),  // send to self for the probe
    sourceSigner: toBytes32(address),
    destinationCaller: ZERO32,
    value,
    salt: randomSalt(),
    hookData: '0x',
  }
  const maxFee = units(Math.max(0.01, PROBE_AMOUNT * 0.001))

  const typedData = {
    types: {
      EIP712Domain: [
        { name: 'name', type: 'string' },
        { name: 'version', type: 'string' },
      ],
      TransferSpec: [
        { name: 'version', type: 'uint32' },
        { name: 'sourceDomain', type: 'uint32' },
        { name: 'destinationDomain', type: 'uint32' },
        { name: 'sourceContract', type: 'bytes32' },
        { name: 'destinationContract', type: 'bytes32' },
        { name: 'sourceToken', type: 'bytes32' },
        { name: 'destinationToken', type: 'bytes32' },
        { name: 'sourceDepositor', type: 'bytes32' },
        { name: 'destinationRecipient', type: 'bytes32' },
        { name: 'sourceSigner', type: 'bytes32' },
        { name: 'destinationCaller', type: 'bytes32' },
        { name: 'value', type: 'uint256' },
        { name: 'salt', type: 'bytes32' },
        { name: 'hookData', type: 'bytes' },
      ],
      BurnIntent: [
        { name: 'maxBlockHeight', type: 'uint256' },
        { name: 'maxFee', type: 'uint256' },
        { name: 'spec', type: 'TransferSpec' },
      ],
    },
    domain: { name: 'GatewayWallet', version: '1' },
    primaryType: 'BurnIntent',
    message: { maxBlockHeight, maxFee, spec },
  }

  // 3a. backend sign — the linchpin. EOA wallet, no user token.
  let signature
  try {
    console.log('  3a. signTypedData (backend, EOA float wallet)...')
    const sig = await c.signTypedData({ walletId: WALLET_ID, data: JSON.stringify(typedData) })
    signature = sig.data?.signature
    console.log('     signature:', signature ? signature.slice(0, 20) + '…' : '(none)')
    if (!signature) { console.log('  → no signature returned; stopping'); return }
  } catch (e) {
    console.log('  SIGN ERROR:', e?.code ?? '', e?.message)
    if (e?.response?.data) console.log('  response.data:', JSON.stringify(e.response.data).slice(0, 300))
    return
  }

  // 3b. submit to /transfer
  try {
    console.log('  3b. POST /transfer ...')
    const res = await fetch(`${GATEWAY_API}/transfer`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify([{ burnIntent: { maxBlockHeight, maxFee, spec }, signature }]),
    })
    const text = await res.text()
    console.log('  /transfer status:', res.status)
    console.log('  /transfer body:', text.slice(0, 500))
    if (res.ok) {
      console.log('  → ATTESTATION RECEIVED. The EOA backend burn-intent path WORKS.')
      console.log('    (Next real step would be gatewayMint on the destination with this attestation.)')
    } else {
      console.log('  → /transfer rejected. Read the message above: it names the exact problem')
      console.log('    (e.g. required maxBlockHeight, insufficient balance, signer mismatch).')
    }
  } catch (e) {
    console.log('  TRANSFER ERROR:', e?.message)
  }
}

// ── Run ─────────────────────────────────────────────────────────────────────
;(async () => {
  console.log('Gateway backend probe — float wallet:', WALLET_ID)
  const address = await getFloatAddress()
  console.log('float address:', address)
  if (!address) { console.log('Could not read float address; aborting.'); process.exit(1) }

  await step1_balance(address)
  const deposited = await step2_deposit()
  if (deposited) {
    console.log('\n(waiting ~10s for Gateway to credit the deposit before balance re-check)')
    await new Promise(r => setTimeout(r, 10000))
    await step1_balance(address)
  }
  await step3_burnIntent(address)

  console.log('\n=== DONE ===')
  console.log('Interpretation:')
  console.log('  • STEP 3 /transfer OK  → backend EOA Gateway payout is viable; build it.')
  console.log('  • STEP 3 signer error  → EOA signature not matching sourceSigner; check')
  console.log('    that float address == sourceSigner (it is, in this probe).')
  console.log('  • STEP 3 balance error → deposit not yet credited; re-run after finality.')
  console.log('  • STEP 2 approve/deposit error → deposit path needs fixing first.')
  console.log('\nDelete this file when done (it references secrets via env).')
})()
PROBE_SRC_EOF

echo "==> Running probe (from afrifx-api so it finds node_modules + .env)"
echo
cd "$API"
set +e
node gateway-probe.mjs
CODE=$?
set -e
echo
if [ $CODE -ne 0 ]; then
  echo "---------------------------------------------------------------"
  echo "The probe exited with an error (code $CODE)."
  echo "If it said env vars are missing, your values aren't in afrifx-api/.env."
  echo "Run it inline with your real values instead:"
  echo
  echo "  cd afrifx-api"
  echo "  CIRCLE_API_KEY=... CIRCLE_ENTITY_SECRET=... \\"
  echo "  PAYROLL_DISBURSEMENT_WALLET_ID=... node gateway-probe.mjs"
  echo "---------------------------------------------------------------"
fi

echo "==> Cleaning up (removing the probe file so it isn't committed)"
rm -f "$API/gateway-probe.mjs"
echo "Done. Paste the STEP 1/2/3 output above."
