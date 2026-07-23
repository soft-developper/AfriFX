// ============================================================
// Circle Gateway configuration (TREASURY use).
//
// STAGE 1: PURE CONFIG + READ-ONLY. Nothing here signs or moves money.
//
// WHY GATEWAY FOR TREASURY (and NOT for user bridging):
// Gateway is a PRE-FUNDED UNIFIED BALANCE, not a faster bridge. You deposit
// once, wait for finality once, then spend instantly (<500ms) on any supported
// chain. Circle's own guidance is explicit that CCTP remains the better fit for
// ad-hoc point-to-point transfers — which is what our user-facing bridge does.
//
// For AfriFX's TREASURY it's a strong fit, and one number makes it compelling:
//
//   DEPOSIT FINALITY (Circle's published figures)
//     Arc       ~0.5 seconds     <-- our home chain
//     Base      ~13-19 minutes
//     Ethereum  ~13-19 minutes
//
// Because Arc finalises in about half a second, the "front-load the wait" cost
// that makes Gateway awkward elsewhere barely exists for us. Treasury sits on
// Arc, deposits near-instantly, and can then fund a Flutterwave payout on Base
// in under a second — instead of a CCTP bridge with an attestation wait sitting
// in the middle of a customer's payout.
//
// Verified against BOTH Circle's and Arc's official docs (they agree):
//   * Gateway uses the SAME domain identifiers as CCTP (Arc = 26), so our
//     existing chain registry carries over unchanged.
//   * Arc Testnet Gateway contracts match Arc's own contract-address page.
// ============================================================

export type GatewayEnv = 'testnet' | 'mainnet'

export const GATEWAY_ENV: GatewayEnv =
  (process.env.NEXT_PUBLIC_CCTP_ENV as GatewayEnv) ?? 'testnet'

export const GATEWAY_API = {
  testnet: 'https://gateway-api-testnet.circle.com/v1',
  mainnet: 'https://gateway-api.circle.com/v1',
} as const

export function gatewayApi(env: GatewayEnv = GATEWAY_ENV) {
  return GATEWAY_API[env]
}

/*
  Gateway contract addresses.

  Arc Testnet values cross-checked against Arc's own contract-address docs.
  NOTE the deposit warning in Circle's technical guide: sending USDC to the
  GatewayWallet with a PLAIN ERC-20 TRANSFER DESTROYS IT. Deposits must go
  through the contract's deposit* methods. Stage 3 will guard against this.
*/
export const GATEWAY_CONTRACTS: Record<GatewayEnv, {
  wallet: string; minter: string
}> = {
  testnet: {
    wallet: '0x0077777d7EBA4688BDeF3E311b846F25870A19B9',
    minter: '0x0022222ABE238Cc2C7Bb1f21003F0a260052475B',
  },
  mainnet: {
    // Same deterministic addresses Circle publishes for mainnet Gateway.
    wallet: '0x0077777d7EBA4688BDeF3E311b846F25870A19B9',
    minter: '0x0022222ABE238Cc2C7Bb1f21003F0a260052475B',
  },
}

export function gatewayContracts(env: GatewayEnv = GATEWAY_ENV) {
  return GATEWAY_CONTRACTS[env]
}

export interface GatewayChain {
  key:      string
  name:     string
  domain:   number     // same identifiers as CCTP
  /** Circle's SupportedChainName, used by the SDK and API. */
  sdkName:  string
  /** Published deposit finality, for honest UI copy. */
  finality: string
  isHome?:  boolean
}

/*
  A deliberately SHORT list: the chains AfriFX actually settles on. Gateway
  supports many more, but each one we show should be one we've reasoned about.
  Arc is home; Base matters because that's where Flutterwave settles.
*/
const TESTNET: GatewayChain[] = [
  { key: 'arc',      name: 'Arc Testnet',      domain: 26, sdkName: 'Arc_Testnet',      finality: '~0.5s', isHome: true },
  { key: 'base',     name: 'Base Sepolia',     domain: 6,  sdkName: 'Base_Sepolia',     finality: '~13-19 min' },
  { key: 'ethereum', name: 'Ethereum Sepolia', domain: 0,  sdkName: 'Ethereum_Sepolia', finality: '~13-19 min' },
  { key: 'arbitrum', name: 'Arbitrum Sepolia', domain: 3,  sdkName: 'Arbitrum_Sepolia', finality: '~13-19 min' },
  { key: 'polygon',  name: 'Polygon Amoy',     domain: 7,  sdkName: 'Polygon_Amoy',     finality: '~8s' },
]

const MAINNET: GatewayChain[] = [
  { key: 'arc',      name: 'Arc',      domain: 26, sdkName: 'Arc',      finality: '~0.5s', isHome: true },
  { key: 'base',     name: 'Base',     domain: 6,  sdkName: 'Base',     finality: '~13-19 min' },
  { key: 'ethereum', name: 'Ethereum', domain: 0,  sdkName: 'Ethereum', finality: '~13-19 min' },
  { key: 'arbitrum', name: 'Arbitrum', domain: 3,  sdkName: 'Arbitrum', finality: '~13-19 min' },
  { key: 'polygon',  name: 'Polygon',  domain: 7,  sdkName: 'Polygon',  finality: '~8s' },
]

export function gatewayChains(env: GatewayEnv = GATEWAY_ENV): GatewayChain[] {
  return env === 'mainnet' ? MAINNET : TESTNET
}

export function gatewayChainByDomain(domain: number, env: GatewayEnv = GATEWAY_ENV) {
  return gatewayChains(env).find(c => c.domain === domain)
}

/*
  WHOSE balance are we showing?

  /treasury is a PER-USER page (it reads the connected wallet), so the Gateway
  panel must show the CONNECTED USER'S OWN unified balance — never a hardcoded
  company address. An earlier draft of this file used a single
  NEXT_PUBLIC_TREASURY_ADDRESS, which would have shown AfriFX's operational
  balance to every user: confusing, and a disclosure of company finances.

  Gateway is permissionless and non-custodial, so every user can have their own
  unified balance keyed to their own wallet. AfriFX's company treasury is simply
  one more wallet — it isn't special-cased here.
*/
export function isValidAddress(a?: string | null): boolean {
  return !!a && /^0x[a-fA-F0-9]{40}$/.test(a)
}

// ── Read-only API helpers ───────────────────────────────────

export interface GatewayBalanceEntry {
  domain:   number
  chainName?: string
  balance:  string
}

export interface GatewayBalances {
  token: string
  total: number
  perChain: { key: string; name: string; domain: number; amount: number; finality: string }[]
  raw?: unknown
}

/*
  Fetch the unified balance for an address.

  Defensive about the response shape: Circle documents `/v1/balances`, but the
  exact nesting has varied between the API reference and the SDK. We normalise
  whatever comes back rather than assuming one shape and rendering NaN.
*/
export async function fetchGatewayBalances(
  address: string, env: GatewayEnv = GATEWAY_ENV,
): Promise<GatewayBalances | { error: string }> {
  try {
    const url = `${gatewayApi(env)}/balances?token=USDC&depositor=${address}`
    const res = await fetch(url, { headers: { accept: 'application/json' } })
    if (!res.ok) return { error: `Gateway API ${res.status}` }
    const data: any = await res.json()

    // Accept several plausible shapes.
    const entries: any[] =
      data?.balances ?? data?.data?.balances ?? data?.data ?? []

    const chains = gatewayChains(env)
    const perChain = chains.map(c => {
      const hit = (Array.isArray(entries) ? entries : []).find((e: any) =>
        Number(e?.domain) === c.domain ||
        String(e?.chain ?? '').toLowerCase() === c.sdkName.toLowerCase())
      return {
        key: c.key, name: c.name, domain: c.domain, finality: c.finality,
        amount: Number(hit?.balance ?? hit?.available ?? 0) || 0,
      }
    })

    const total =
      Number(data?.totalBalance ?? data?.total ?? 0) ||
      perChain.reduce((s, c) => s + c.amount, 0)

    return { token: 'USDC', total, perChain, raw: data }
  } catch (err: any) {
    return { error: err?.message ?? 'Could not reach the Gateway API' }
  }
}

// ── Deposit (stage 3) ───────────────────────────────────────

/*
  GatewayWallet ABI — only the pieces we call.

  Signature confirmed from Circle's own integration guide:
      deposit(address token, uint256 amount)
  The resulting balance belongs to the FUNCTION CALLER, which is what we want:
  the connected user deposits for themselves.
*/
export const GATEWAY_WALLET_ABI = [
  {
    type: 'function', name: 'deposit', stateMutability: 'nonpayable',
    inputs: [
      { name: 'token',  type: 'address' },
      { name: 'amount', type: 'uint256' },
    ],
    outputs: [],
  },
  {
    // Deposit crediting SOMEONE ELSE's balance. Not used by the UI, but
    // included so the ABI is complete and the difference is documented:
    // `deposit` credits msg.sender, `depositFor` credits `depositor`.
    type: 'function', name: 'depositFor', stateMutability: 'nonpayable',
    inputs: [
      { name: 'token',     type: 'address' },
      { name: 'depositor', type: 'address' },
      { name: 'amount',    type: 'uint256' },
    ],
    outputs: [],
  },
  {
    type: 'function', name: 'availableBalance', stateMutability: 'view',
    inputs: [
      { name: 'token',     type: 'address' },
      { name: 'depositor', type: 'address' },
    ],
    outputs: [{ name: '', type: 'uint256' }],
  },
] as const

export const GATEWAY_ERC20_ABI = [
  {
    type: 'function', name: 'approve', stateMutability: 'nonpayable',
    inputs: [{ name: 'spender', type: 'address' }, { name: 'amount', type: 'uint256' }],
    outputs: [{ name: '', type: 'bool' }],
  },
  {
    type: 'function', name: 'allowance', stateMutability: 'view',
    inputs: [{ name: 'owner', type: 'address' }, { name: 'spender', type: 'address' }],
    outputs: [{ name: '', type: 'uint256' }],
  },
  {
    type: 'function', name: 'balanceOf', stateMutability: 'view',
    inputs: [{ name: 'account', type: 'address' }],
    outputs: [{ name: '', type: 'uint256' }],
  },
] as const

/*
  *** THE MOST DANGEROUS MISTAKE IN GATEWAY ***

  Circle's docs: "Directly transferring USDC to the Gateway Wallet contract with
  a standard ERC-20 transfer will result in loss of that USDC."

  There is no recovery. So this guard exists to make that mistake structurally
  impossible from our code: any call that would send USDC to the GatewayWallet
  via `transfer` is rejected before it can be signed.

  Deposits MUST go through the wallet contract's deposit() method, which is what
  useGatewayDeposit does.
*/
export function assertNotPlainTransfer(fnName: string, to: string, env: GatewayEnv = GATEWAY_ENV) {
  const wallet = gatewayContracts(env).wallet.toLowerCase()
  if (to.toLowerCase() === wallet && /^(transfer|transferFrom|send)$/i.test(fnName)) {
    throw new Error(
      'Refusing to send USDC directly to the Gateway Wallet — a plain ERC-20 ' +
      'transfer to that contract permanently destroys the funds. Use deposit() instead.',
    )
  }
}

// USDC is 6 decimals on every Gateway chain.
export function usdcToUnits(amount: number): bigint {
  const [whole, frac = ''] = String(amount).split('.')
  const padded = (frac + '000000').slice(0, 6)
  return BigInt(whole || '0') * BigInt(1000000) + BigInt(padded || '0')
}
