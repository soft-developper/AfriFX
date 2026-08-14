#!/usr/bin/env bash
# gateway-probe3.sh - derive float onto Base (FIXED param), then full transfer+mint.
# Run from repo root:  bash gateway-probe3.sh   (add DO_DEPOSIT=1 to top up first)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; API="$ROOT/afrifx-api"
[ -d "$API" ] || { echo "ERR: run from AfriFX repo root"; exit 1; }
[ -d "$API/node_modules/@circle-fin/developer-controlled-wallets" ] || { echo "ERR: cd afrifx-api && npm install first"; exit 1; }
echo "==> Writing gateway-probe3.mjs into afrifx-api"
cat > "$API/gateway-probe3.mjs" << 'PROBE_SRC_EOF'
// ============================================================================
// gateway-probe3.mjs — Derive float onto Base, then FULL round-trip mint.
//
// Proven so far: deposit, balance, EOA burn-intent signature, Circle attestation.
// Unproven: the MINT, because the float is an Arc wallet with no Base address.
// FIX (this probe): deriveWallet() gives the float a Base-Sepolia address under
// the SAME wallet id + entity secret. Then we do a fresh transfer and mint the
// attestation FROM the Base-derived wallet. If the mint confirms, the entire
// backend cross-chain send is proven end to end.
//
// deriveWallet is idempotent-ish: calling it when already derived returns the
// existing address. Safe to re-run.
//
// RUN (wrapped):  cd ~/AfriFX && bash gateway-probe3.sh
// Moves at most PROBE_AMOUNT (default 0.05) USDC of the float's Gateway balance,
// minting to the float's own Base address. Set DO_DEPOSIT=1 to top up first.
// ============================================================================
import 'dotenv/config'
import { initiateDeveloperControlledWalletsClient } from '@circle-fin/developer-controlled-wallets'

const API_KEY   = process.env.CIRCLE_API_KEY
const SECRET    = process.env.CIRCLE_ENTITY_SECRET
const WALLET_ID = process.env.PAYROLL_DISBURSEMENT_WALLET_ID
const GATEWAY_API = process.env.NEXT_PUBLIC_CCTP_ENV === 'mainnet'
  ? 'https://gateway-api.circle.com/v1' : 'https://gateway-api-testnet.circle.com/v1'
const PROBE_AMOUNT = Number(process.env.PROBE_AMOUNT ?? '0.05')
const DO_DEPOSIT   = process.env.DO_DEPOSIT === '1'

const GATEWAY_WALLET = '0x0077777d7EBA4688BDeF3E311b846F25870A19B9'
const GATEWAY_MINTER = '0x0022222ABE238Cc2C7Bb1f21003F0a260052475B'
const USDC = { arc: process.env.NEXT_PUBLIC_ARC_USDC ?? '0x3600000000000000000000000000000000000000',
               base: '0x036CbD53842c5426634e7929541eC2318f3dCF7e' }
const SRC_DOMAIN = 26, DST_DOMAIN = 6
const DST_BLOCKCHAIN = 'BASE-SEPOLIA'

if (!API_KEY || !SECRET || !WALLET_ID) { console.error('Missing env'); process.exit(1) }
const c = initiateDeveloperControlledWalletsClient({ apiKey: API_KEY, entitySecret: SECRET })

const units = (u) => BigInt(Math.round(u * 1e6)).toString()
const toB32 = (a) => `0x${'0'.repeat(24)}${a.toLowerCase().replace(/^0x/, '')}`
const ZERO32 = `0x${'0'.repeat(64)}`
function salt() { const b = new Uint8Array(32); globalThis.crypto.getRandomValues(b)
  return `0x${Array.from(b).map(x => x.toString(16).padStart(2, '0')).join('')}` }
async function floatAddr() { return (await c.getWallet({ id: WALLET_ID })).data?.wallet?.address }
async function waitTx(id, tries = 14) {
  if (!id) return null
  for (let i = 0; i < tries; i++) {
    try { const t = await c.getTransaction({ id }); const st = t.data?.transaction?.state
      if (['CONFIRMED','COMPLETE','SENT'].includes(st)) return { st, txHash: t.data?.transaction?.txHash }
      if (['FAILED','DENIED','CANCELLED'].includes(st)) return { st, txHash: null, reason: t.data?.transaction?.errorReason, details: t.data?.transaction?.errorDetails } }
    catch {}
    await new Promise(r => setTimeout(r, 3000)) }
  return { st: 'PENDING' }
}
const TYPES = {
  EIP712Domain: [{name:'name',type:'string'},{name:'version',type:'string'}],
  TransferSpec: [{name:'version',type:'uint32'},{name:'sourceDomain',type:'uint32'},{name:'destinationDomain',type:'uint32'},{name:'sourceContract',type:'bytes32'},{name:'destinationContract',type:'bytes32'},{name:'sourceToken',type:'bytes32'},{name:'destinationToken',type:'bytes32'},{name:'sourceDepositor',type:'bytes32'},{name:'destinationRecipient',type:'bytes32'},{name:'sourceSigner',type:'bytes32'},{name:'destinationCaller',type:'bytes32'},{name:'value',type:'uint256'},{name:'salt',type:'bytes32'},{name:'hookData',type:'bytes'}],
  BurnIntent: [{name:'maxBlockHeight',type:'uint256'},{name:'maxFee',type:'uint256'},{name:'spec',type:'TransferSpec'}],
}

async function main() {
  const address = await floatAddr()
  console.log('float (Arc) address:', address)

  // ── STEP A: derive the float onto Base ──────────────────────────────────
  console.log('\n=== STEP A: derive float onto Base Sepolia ===')
  let baseAddr
  try {
    const d = await c.deriveWallet({ id: WALLET_ID, blockchain: DST_BLOCKCHAIN })
    // response shape can be { wallets:[...] } or { wallet:{...} }; handle both
    const w = d.data?.wallets?.[0] ?? d.data?.wallet ?? d.data
    baseAddr = w?.address ?? address
    console.log('  derived/base address:', baseAddr, '| id:', w?.id ?? '(same wallet)')
  } catch (e) {
    // Already-derived often returns an error we can treat as "already exists".
    console.log('  deriveWallet note:', e?.code ?? '', e?.message)
    baseAddr = address
    console.log('  proceeding with float address on Base:', baseAddr)
  }

  if (DO_DEPOSIT) {
    console.log(`\n=== deposit ${PROBE_AMOUNT} (DO_DEPOSIT=1) ===`)
    const amt = units(PROBE_AMOUNT)
    const ap = await c.createContractExecutionTransaction({ walletId: WALLET_ID, contractAddress: USDC.arc, abiFunctionSignature: 'approve(address,uint256)', abiParameters: [GATEWAY_WALLET, amt], fee: { type:'level', config:{ feeLevel:'MEDIUM' } } })
    console.log('  approve:', (await waitTx(ap.data?.id))?.st)
    const dp = await c.createContractExecutionTransaction({ walletId: WALLET_ID, contractAddress: GATEWAY_WALLET, abiFunctionSignature: 'deposit(address,uint256)', abiParameters: [USDC.arc, amt], fee: { type:'level', config:{ feeLevel:'MEDIUM' } } })
    console.log('  deposit:', (await waitTx(dp.data?.id))?.st)
    await new Promise(r => setTimeout(r, 10000))
  }

  const bal = JSON.parse(await (await fetch(`${GATEWAY_API}/balances`, { method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify({ token:'USDC', sources:[{domain:SRC_DOMAIN, depositor:address}] }) })).text())
  console.log('\nArc Gateway balance:', bal?.balances?.[0]?.balance ?? '?')

  // ── STEP B: transfer (recipient = base address) ─────────────────────────
  const value = units(PROBE_AMOUNT)
  const spec = { version:1, sourceDomain:SRC_DOMAIN, destinationDomain:DST_DOMAIN,
    sourceContract:toB32(GATEWAY_WALLET), destinationContract:toB32(GATEWAY_MINTER),
    sourceToken:toB32(USDC.arc), destinationToken:toB32(USDC.base),
    sourceDepositor:toB32(address), destinationRecipient:toB32(baseAddr),
    sourceSigner:toB32(address), destinationCaller:ZERO32, value, salt:salt(), hookData:'0x' }
  const maxFee = units(Math.max(0.01, PROBE_AMOUNT * 0.001))
  async function signTransfer(mbh) {
    const td = { types:TYPES, domain:{name:'GatewayWallet',version:'1'}, primaryType:'BurnIntent',
      message:{ maxBlockHeight:mbh.toString(), maxFee, spec:{...spec, value} } }
    const sig = (await c.signTypedData({ walletId: WALLET_ID, data: JSON.stringify(td) })).data?.signature
    const res = await fetch(`${GATEWAY_API}/transfer`, { method:'POST', headers:{'Content-Type':'application/json'},
      body: JSON.stringify([{ burnIntent:{ maxBlockHeight:mbh.toString(), maxFee, spec:{...spec, value} }, signature: sig }]) })
    const t = await res.text()
    if (!res.ok) { const m = t.match(/expected at least (\d+)/i); const e = new Error(`transfer ${res.status}: ${t.slice(0,200)}`); if (m) e.__req = BigInt(m[1]); throw e }
    return JSON.parse(t || '{}')
  }
  console.log('\n=== STEP B: transfer ===')
  let data, mbh = BigInt(10)**BigInt(15)
  try { data = await signTransfer(mbh) }
  catch (e) { if (e.__req) { mbh = e.__req + BigInt(500000); data = await signTransfer(mbh) } else { console.log('  FAILED:', e.message); process.exit(0) } }
  const att = data?.attestation ?? data?.attestations?.[0]?.attestation
  const asig = data?.signature ?? data?.attestations?.[0]?.signature
  console.log('  attestation:', att ? 'YES' : 'NO')
  if (!att || !asig) process.exit(0)

  // ── STEP C: mint from the Base-derived wallet ───────────────────────────
  console.log('\n=== STEP C: mint on Base (from derived wallet) ===')
  try {
    const mint = await c.createContractExecutionTransaction({
      walletId: WALLET_ID,   // same wallet id; Circle routes to its Base address for a Base contract
      contractAddress: GATEWAY_MINTER,
      abiFunctionSignature: 'gatewayMint(bytes,bytes)', abiParameters: [att, asig],
      fee: { type:'level', config:{ feeLevel:'MEDIUM' } },
    })
    console.log('  mint id:', mint.data?.id, 'state:', mint.data?.state)
    const r = await waitTx(mint.data?.id)
    console.log('  mint final:', r?.st, r?.txHash ? `hash ${r.txHash}` : (r?.reason ? `(${r.reason}: ${r.details})` : ''))
    if (r?.txHash) {
      console.log('\n  ✅ FULL ROUND-TRIP CONFIRMED. Base tx:', r.txHash)
      console.log('     Backend EOA Gateway send works end to end. Building the service is now safe.')
    } else if (r?.st === 'FAILED') {
      console.log('\n  Transfer+attestation proven. Mint still failing — paste the reason above.')
      console.log('  If it is a blockchain/wallet mismatch, the derive step may need the wallet')
      console.log('  to be on a specific SCA/EOA core; we adjust from the exact reason.')
    }
  } catch (e) {
    console.log('  MINT ERROR:', e?.code ?? '', e?.message)
    if (e?.response?.data) console.log('  data:', JSON.stringify(e.response.data).slice(0,300))
  }
  console.log('\n=== DONE ===')
}
main().catch(e => { console.error('FATAL:', e?.message); process.exit(1) })
PROBE_SRC_EOF
echo "==> Running (from afrifx-api)"; echo
cd "$API"; set +e; node gateway-probe3.mjs; CODE=$?; set -e; echo
[ $CODE -ne 0 ] && echo "Exited $CODE."
echo "==> Cleaning up"; rm -f "$API/gateway-probe3.mjs"; echo "Done. Paste output above."
