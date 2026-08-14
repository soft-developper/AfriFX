#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; API="$ROOT/afrifx-api"
[ -d "$API" ] || { echo "ERR: run from AfriFX repo root"; exit 1; }
echo "==> Writing gateway-probe4.mjs"
cat > "$API/gateway-probe4.mjs" << '''PROBE_SRC_EOF'''
// gateway-probe4.mjs — DUMP the raw /transfer response. No mint. Diagnostic only.
// The mint reverts with InvalidAttestationSigner(), meaning the signature passed
// to gatewayMint doesn't recover to a Circle-registered signer. Most likely the
// response field we read for "signature" is wrong. This prints the ACTUAL JSON
// so we stop guessing.
import 'dotenv/config'
import { initiateDeveloperControlledWalletsClient } from '@circle-fin/developer-controlled-wallets'

const API_KEY=process.env.CIRCLE_API_KEY, SECRET=process.env.CIRCLE_ENTITY_SECRET, WALLET_ID=process.env.PAYROLL_DISBURSEMENT_WALLET_ID
const GATEWAY_API = 'https://gateway-api-testnet.circle.com/v1'
const GATEWAY_WALLET='0x0077777d7EBA4688BDeF3E311b846F25870A19B9', GATEWAY_MINTER='0x0022222ABE238Cc2C7Bb1f21003F0a260052475B'
const USDC={arc:'0x3600000000000000000000000000000000000000',base:'0x036CbD53842c5426634e7929541eC2318f3dCF7e'}
const PROBE_AMOUNT=Number(process.env.PROBE_AMOUNT ?? '0.02')
if(!API_KEY||!SECRET||!WALLET_ID){console.error('missing env');process.exit(1)}
const c=initiateDeveloperControlledWalletsClient({apiKey:API_KEY,entitySecret:SECRET})
const units=u=>BigInt(Math.round(u*1e6)).toString()
const toB32=a=>`0x${'0'.repeat(24)}${a.toLowerCase().replace(/^0x/,'')}`
const ZERO32=`0x${'0'.repeat(64)}`
function salt(){const b=new Uint8Array(32);globalThis.crypto.getRandomValues(b);return `0x${Array.from(b).map(x=>x.toString(16).padStart(2,'0')).join('')}`}
const TYPES={EIP712Domain:[{name:'name',type:'string'},{name:'version',type:'string'}],TransferSpec:[{name:'version',type:'uint32'},{name:'sourceDomain',type:'uint32'},{name:'destinationDomain',type:'uint32'},{name:'sourceContract',type:'bytes32'},{name:'destinationContract',type:'bytes32'},{name:'sourceToken',type:'bytes32'},{name:'destinationToken',type:'bytes32'},{name:'sourceDepositor',type:'bytes32'},{name:'destinationRecipient',type:'bytes32'},{name:'sourceSigner',type:'bytes32'},{name:'destinationCaller',type:'bytes32'},{name:'value',type:'uint256'},{name:'salt',type:'bytes32'},{name:'hookData',type:'bytes'}],BurnIntent:[{name:'maxBlockHeight',type:'uint256'},{name:'maxFee',type:'uint256'},{name:'spec',type:'TransferSpec'}]}

const w=await c.getWallet({id:WALLET_ID}); const address=w.data?.wallet?.address
console.log('float:',address)
const value=units(PROBE_AMOUNT)
const spec={version:1,sourceDomain:26,destinationDomain:6,sourceContract:toB32(GATEWAY_WALLET),destinationContract:toB32(GATEWAY_MINTER),sourceToken:toB32(USDC.arc),destinationToken:toB32(USDC.base),sourceDepositor:toB32(address),destinationRecipient:toB32(address),sourceSigner:toB32(address),destinationCaller:ZERO32,value,salt:salt(),hookData:'0x'}
const maxFee=units(0.01)
const mbh=(BigInt(10)**BigInt(15)).toString()
const td={types:TYPES,domain:{name:'GatewayWallet',version:'1'},primaryType:'BurnIntent',message:{maxBlockHeight:mbh,maxFee,spec:{...spec,value}}}
const mySig=(await c.signTypedData({walletId:WALLET_ID,data:JSON.stringify(td)})).data?.signature
console.log('\nMY burn-intent signature (for comparison):', mySig)
const res=await fetch(`${GATEWAY_API}/transfer`,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify([{burnIntent:{maxBlockHeight:mbh,maxFee,spec:{...spec,value}},signature:mySig}])})
const text=await res.text()
console.log('\n=== RAW /transfer RESPONSE (status',res.status,') ===')
console.log(text)
console.log('\n=== PARSED STRUCTURE ===')
try{
  const d=JSON.parse(text)
  console.log('top-level keys:', Object.keys(d))
  console.log('attestation:', typeof d.attestation, d.attestation ? String(d.attestation).slice(0,40)+'…' : d.attestation)
  console.log('signature:', typeof d.signature, d.signature ? String(d.signature).slice(0,40)+'…' : d.signature)
  if(d.attestations) console.log('attestations[0] keys:', Object.keys(d.attestations[0]||{}))
  console.log('\nIs the response .signature === my burn-intent signature?',
    d.signature===mySig ? 'YES - passing OUR signature to mint, not Circle attestation sig. BUG FOUND.' : 'No - response.signature is distinct.')
}catch(e){console.log('parse error:',e.message)}
console.log('\n(no mint performed — diagnostic only)')
PROBE_SRC_EOF
echo "==> Running"; echo
cd "$API"; set +e; node gateway-probe4.mjs; set -e; echo
echo "==> Cleaning up"; rm -f "$API/gateway-probe4.mjs"; echo "Done. Paste the RAW RESPONSE + PARSED STRUCTURE above."
