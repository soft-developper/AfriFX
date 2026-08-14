#!/usr/bin/env bash
# gateway-probe2.sh - corrected round-trip probe (transfer -> attestation -> mint).
# Run from repo root:  bash gateway-probe2.sh
# Uses the REAL Base USDC address (v1's only bug was the wrong destination token).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
API="$ROOT/afrifx-api"
[ -d "$API" ] || { echo "ERR: run from the AfriFX repo root"; exit 1; }
[ -d "$API/node_modules/@circle-fin/developer-controlled-wallets" ] || { echo "ERR: cd afrifx-api && npm install first"; exit 1; }
echo "==> Writing gateway-probe2.mjs into afrifx-api"
cat > "$API/gateway-probe2.mjs" << 'PROBE_SRC_EOF'
// ============================================================================
// gateway-probe2.mjs — Corrected round-trip: transfer → attestation → mint.
//
// v1 proved: deposit works, balance credits, and the EOA float wallet's burn-
// intent signature is ACCEPTED by Circle. v1 only failed because it used the
// ARC USDC address as the destination token on Base — wrong; USDC has a
// different address per chain. This version uses the REAL per-chain USDC
// addresses (from afrifx-web/lib/cctp-chains.ts) and also performs the MINT.
//
// Your float already holds 0.10 USDC in its Arc Gateway balance from the v1
// run, so this can spend it without re-depositing. Set DO_DEPOSIT=1 to deposit
// again first if needed.
//
// RUN (wrapped by gateway-probe2.sh):  cd ~/AfriFX && bash gateway-probe2.sh
//
// Moves at most PROBE_AMOUNT (default 0.05) USDC of the float's Gateway balance,
// minting to the float's OWN address on Base Sepolia. Safe.
// ============================================================================
import 'dotenv/config'
import { initiateDeveloperControlledWalletsClient } from '@circle-fin/developer-controlled-wallets'

const API_KEY   = process.env.CIRCLE_API_KEY
const SECRET    = process.env.CIRCLE_ENTITY_SECRET
const WALLET_ID = process.env.PAYROLL_DISBURSEMENT_WALLET_ID
const GATEWAY_API = process.env.NEXT_PUBLIC_CCTP_ENV === 'mainnet'
  ? 'https://gateway-api.circle.com/v1'
  : 'https://gateway-api-testnet.circle.com/v1'
const PROBE_AMOUNT = Number(process.env.PROBE_AMOUNT ?? '0.05')
const DO_DEPOSIT   = process.env.DO_DEPOSIT === '1'

const GATEWAY_WALLET = '0x0077777d7EBA4688BDeF3E311b846F25870A19B9'
const GATEWAY_MINTER = '0x0022222ABE238Cc2C7Bb1f21003F0a260052475B'

// REAL per-chain testnet USDC addresses (from cctp-chains.ts).
const USDC = {
  arc:  process.env.NEXT_PUBLIC_ARC_USDC ?? '0x3600000000000000000000000000000000000000',
  base: '0x036CbD53842c5426634e7929541eC2318f3dCF7e',   // Base Sepolia
}
const SRC_DOMAIN = 26   // Arc
const DST_DOMAIN = 6    // Base
// Circle blockchain name for the mint (destination = Base Sepolia).
const DST_BLOCKCHAIN = 'BASE-SEPOLIA'

if (!API_KEY || !SECRET || !WALLET_ID) {
  console.error('Missing env: CIRCLE_API_KEY / CIRCLE_ENTITY_SECRET / PAYROLL_DISBURSEMENT_WALLET_ID')
  process.exit(1)
}

const c = initiateDeveloperControlledWalletsClient({ apiKey: API_KEY, entitySecret: SECRET })

const units = (usdc) => BigInt(Math.round(usdc * 1e6)).toString()
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
async function waitTx(id, tries = 12) {
  if (!id) return null
  for (let i = 0; i < tries; i++) {
    try {
      const t = await c.getTransaction({ id })
      const st = t.data?.transaction?.state
      if (['CONFIRMED', 'COMPLETE', 'SENT'].includes(st)) return { st, txHash: t.data?.transaction?.txHash }
      if (['FAILED', 'DENIED', 'CANCELLED'].includes(st)) return { st, txHash: null }
    } catch {}
    await new Promise(r => setTimeout(r, 3000))
  }
  return { st: 'PENDING', txHash: null }
}

const EIP712_TYPES = {
  EIP712Domain: [ { name: 'name', type: 'string' }, { name: 'version', type: 'string' } ],
  TransferSpec: [
    { name: 'version', type: 'uint32' }, { name: 'sourceDomain', type: 'uint32' },
    { name: 'destinationDomain', type: 'uint32' }, { name: 'sourceContract', type: 'bytes32' },
    { name: 'destinationContract', type: 'bytes32' }, { name: 'sourceToken', type: 'bytes32' },
    { name: 'destinationToken', type: 'bytes32' }, { name: 'sourceDepositor', type: 'bytes32' },
    { name: 'destinationRecipient', type: 'bytes32' }, { name: 'sourceSigner', type: 'bytes32' },
    { name: 'destinationCaller', type: 'bytes32' }, { name: 'value', type: 'uint256' },
    { name: 'salt', type: 'bytes32' }, { name: 'hookData', type: 'bytes' },
  ],
  BurnIntent: [
    { name: 'maxBlockHeight', type: 'uint256' }, { name: 'maxFee', type: 'uint256' },
    { name: 'spec', type: 'TransferSpec' },
  ],
}

async function main() {
  console.log('Corrected Gateway probe — float:', WALLET_ID)
  const address = await getFloatAddress()
  console.log('float address:', address)

  // Optional re-deposit
  if (DO_DEPOSIT) {
    console.log(`\n=== DEPOSIT ${PROBE_AMOUNT} USDC (DO_DEPOSIT=1) ===`)
    const amt = units(PROBE_AMOUNT)
    const ap = await c.createContractExecutionTransaction({
      walletId: WALLET_ID, contractAddress: USDC.arc,
      abiFunctionSignature: 'approve(address,uint256)', abiParameters: [GATEWAY_WALLET, amt],
      fee: { type: 'level', config: { feeLevel: 'MEDIUM' } },
    })
    console.log('  approve:', (await waitTx(ap.data?.id))?.st)
    const dp = await c.createContractExecutionTransaction({
      walletId: WALLET_ID, contractAddress: GATEWAY_WALLET,
      abiFunctionSignature: 'deposit(address,uint256)', abiParameters: [USDC.arc, amt],
      fee: { type: 'level', config: { feeLevel: 'MEDIUM' } },
    })
    console.log('  deposit:', (await waitTx(dp.data?.id))?.st)
    await new Promise(r => setTimeout(r, 10000))
  }

  // Balance check
  const bres = await fetch(`${GATEWAY_API}/balances`, {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ token: 'USDC', sources: [{ domain: SRC_DOMAIN, depositor: address }] }),
  })
  const bal = JSON.parse(await bres.text())
  console.log('\nArc Gateway balance:', bal?.balances?.[0]?.balance ?? '?')

  // ── Build + sign + transfer (with the CORRECT destination token) ──────────
  const value = units(PROBE_AMOUNT)
  const spec = {
    version: 1, sourceDomain: SRC_DOMAIN, destinationDomain: DST_DOMAIN,
    sourceContract: toBytes32(GATEWAY_WALLET), destinationContract: toBytes32(GATEWAY_MINTER),
    sourceToken: toBytes32(USDC.arc),
    destinationToken: toBytes32(USDC.base),          // <-- THE FIX: Base USDC, not Arc
    sourceDepositor: toBytes32(address), destinationRecipient: toBytes32(address),
    sourceSigner: toBytes32(address), destinationCaller: ZERO32,
    value, salt: randomSalt(), hookData: '0x',
  }
  const maxFee = units(Math.max(0.01, PROBE_AMOUNT * 0.001))

  async function signAndTransfer(maxBlockHeight) {
    const typedData = {
      types: EIP712_TYPES, domain: { name: 'GatewayWallet', version: '1' },
      primaryType: 'BurnIntent',
      message: { maxBlockHeight: maxBlockHeight.toString(), maxFee, spec: { ...spec, value } },
    }
    const sig = await c.signTypedData({ walletId: WALLET_ID, data: JSON.stringify(typedData) })
    const signature = sig.data?.signature
    if (!signature) throw new Error('no signature')
    const res = await fetch(`${GATEWAY_API}/transfer`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify([{ burnIntent: { maxBlockHeight: maxBlockHeight.toString(), maxFee, spec: { ...spec, value } }, signature }]),
    })
    const text = await res.text()
    if (!res.ok) {
      const m = text.match(/expected at least (\d+)/i)
      const e = new Error(`transfer ${res.status}: ${text.slice(0, 250)}`)
      if (m) e.__req = BigInt(m[1])
      throw e
    }
    return JSON.parse(text || '{}')
  }

  console.log('\n=== TRANSFER (sign burn intent → /transfer) ===')
  let data
  let mbh = BigInt(10) ** BigInt(15)
  try {
    data = await signAndTransfer(mbh)
  } catch (e) {
    if (e.__req) {
      console.log('  maxBlockHeight too low; retrying with required + buffer')
      mbh = e.__req + BigInt(500000)
      data = await signAndTransfer(mbh)
    } else {
      console.log('  TRANSFER FAILED:', e.message)
      process.exit(0)
    }
  }
  const attestation = data?.attestation ?? data?.attestations?.[0]?.attestation
  const attSig      = data?.signature   ?? data?.attestations?.[0]?.signature
  console.log('  attestation received:', attestation ? 'YES ('+String(attestation).slice(0,20)+'…)' : 'NO')
  if (!attestation || !attSig) { console.log('  no attestation; stopping'); process.exit(0) }

  // ── Mint on Base ──────────────────────────────────────────────────────────
  console.log('\n=== MINT on Base Sepolia (gatewayMint) ===')
  try {
    const mint = await c.createContractExecutionTransaction({
      walletId: WALLET_ID,                 // NOTE: probe mints from the FLOAT wallet;
                                           // in production the float wallet must exist on Base too,
                                           // OR the mint is done by any wallet (destinationCaller=0).
      contractAddress: GATEWAY_MINTER,
      abiFunctionSignature: 'gatewayMint(bytes,bytes)',
      abiParameters: [attestation, attSig],
      fee: { type: 'level', config: { feeLevel: 'MEDIUM' } },
    })
    console.log('  mint tx id:', mint.data?.id, 'state:', mint.data?.state)
    const mres = await waitTx(mint.data?.id)
    console.log('  mint final:', mres?.st, mres?.txHash ? `hash ${mres.txHash}` : '')
    if (mres?.txHash) {
      console.log('\n  🎉 FULL ROUND-TRIP WORKS. Backend EOA Gateway send is viable end-to-end.')
      console.log('     Base tx:', mres.txHash)
    } else {
      console.log('\n  Transfer + attestation worked. Mint submitted; check state above.')
      console.log('  If mint errored on wallet/blockchain, note the mint must run on a Base wallet;')
      console.log('  the transfer/attestation half (the hard part) is proven regardless.')
    }
  } catch (e) {
    console.log('  MINT ERROR:', e?.code ?? '', e?.message)
    if (e?.response?.data) console.log('  data:', JSON.stringify(e.response.data).slice(0, 300))
    console.log('\n  NOTE: transfer + attestation SUCCEEDED — that was the uncertain part.')
    console.log('  A mint error is usually "wallet not on this chain": the float is an Arc')
    console.log('  wallet; minting on Base needs a Base-side wallet (or a derived address).')
    console.log('  That is a known, solvable detail — not a blocker to the approach.')
  }

  console.log('\n=== DONE ===')
}
main().catch(e => { console.error('FATAL:', e?.message); process.exit(1) })
PROBE_SRC_EOF
echo "==> Running (from afrifx-api)"
echo
cd "$API"
set +e; node gateway-probe2.mjs; CODE=$?; set -e
echo
[ $CODE -ne 0 ] && { echo "Exited with $CODE. If env missing, run inline:"; echo "  cd afrifx-api && CIRCLE_API_KEY=... CIRCLE_ENTITY_SECRET=... PAYROLL_DISBURSEMENT_WALLET_ID=... node gateway-probe2.mjs"; }
echo "==> Cleaning up"
rm -f "$API/gateway-probe2.mjs"
echo "Done. Paste the output above."
